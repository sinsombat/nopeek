import Foundation

// MARK: - KindRule

/// One structural signal that turns a log line into a candidate `RawEvent`
/// (spec §5: the classifier assigns tiers; the parser only decides *what was
/// observed*).
///
/// A rule is anchored on a process name and/or a subsystem; `messageContains`
/// narrows it further (at least one needle must appear in the line's
/// `eventMessage`, falling back to `formatString`). A rule with neither
/// `process` nor `subsystem` is too loose to be a signal and never matches —
/// see `LogLineParserTests.testRulesWithoutProcessOrSubsystemNeverMatch`.
///
/// The defaults were chosen against a real capture probe (2026-10-18,
/// ⌘⇧5 screenshot toolbar + Mission Control, 2181 lines; the camera rules came
/// later, from the T14 field-test fix and its own 3956-line probe — see
/// `cameraDefaults`): precision first, so XPC/prefs chatter from
/// `screencaptureui` produces no candidates.
///
/// Mission Control is the deliberate exception (spec §11-2, ruling R14): its
/// use must leave SYSTEM_NOISE lines in the evidence log, so one
/// WindowManager rule ships. The probe's 1273 WindowManager lines are ~99%
/// XPC / connection / window-bookkeeping chatter (880 of them
/// `minimumDockRevealAmountDidChange` alone), so the rule is narrowed to the
/// one signature that marks a Mission Control transition: the `app`-category
/// "Change expose mode …" line — exactly one line per enter/exit (gesture,
/// hotKey and clientToggle paths alike), and the only WindowManager message
/// that is not `<private>`-redacted, so the direction it carries is readable
/// in the evidence line. Everything else WindowManager logs stays a
/// non-candidate.
public struct KindRule: Equatable, Sendable {
    /// `process`-style name: the ndjson `process` key when present, otherwise
    /// the basename of `processImagePath` (real `log stream` output has no
    /// `process` key — verified on the probe).
    public let process: String?
    /// Exact `subsystem` value, e.g. `com.apple.ScreenCaptureKit`.
    public let subsystem: String?
    /// Substrings of which at least one must appear in the line's message.
    public let messageContains: [String]?
    /// Kind assigned when the rule matches.
    public let kind: EventKind
    /// Optional regex (one capture group) that pulls the *client* pid out of
    /// the message when the line's own process is only a broker.
    ///
    /// The v1.1 microphone signal is the motivating case: `coreaudiod` logs
    /// `… PublishRecordingClientInfo: Report client 15522 running: yes …`, so
    /// the process in the line is the daemon and the real actor is the client
    /// it names. The pattern also gates the rule: a line that lacks it is not
    /// a match. When it does match and the pid resolves, the parser replaces
    /// the rule's actor/path/pid with the client's (`LogLineParser`'s injected
    /// `resolveClient`); when it matches but the client cannot be resolved,
    /// the actor degrades to `"mic"` instead of naming the broker.
    public let clientPIDPattern: String?

    public init(
        process: String? = nil,
        subsystem: String? = nil,
        messageContains: [String]? = nil,
        kind: EventKind,
        clientPIDPattern: String? = nil
    ) {
        self.process = process
        self.subsystem = subsystem
        self.messageContains = messageContains
        self.kind = kind
        self.clientPIDPattern = clientPIDPattern
    }

    /// A rule needs a process or subsystem anchor to be a signal.
    var isAnchored: Bool {
        process != nil || subsystem != nil
    }

    func matches(processName: String?, subsystem candidateSubsystem: String?, message: String) -> Bool {
        guard isAnchored else { return false }
        if let process, process != processName { return false }
        if let subsystem, subsystem != candidateSubsystem { return false }
        if let messageContains, !messageContains.isEmpty,
           !messageContains.contains(where: { message.contains($0) }) {
            return false
        }
        // A client-pid rule is defined by its report line: the pattern is not
        // just an attribution extra, it is what separates `running: yes` from
        // `running: no` when the needles above are shared. `… Updated recording
        // status successfully.` carries the function name but no client and
        // must not match.
        if let clientPIDPattern, !Self.pattern(clientPIDPattern, matches: message) {
            return false
        }
        return true
    }

    /// Whether `pattern` matches `message` (unused capture groups are fine).
    private static func pattern(_ pattern: String, matches message: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        return regex.firstMatch(
            in: message,
            range: NSRange(message.startIndex..., in: message)
        ) != nil
    }
}

extension KindRule {

    /// The shipped capture rules, ordered by specificity (first match wins).
    ///
    /// - `replayd`, the process that owns the on-screen capture indicator, is
    ///   the capture-*session* signal: the rule keeps the session variants and
    ///   rejects the ambient one. `…:165 … hasStarted=1` (a stream started for
    ///   a client) and `…_block_invoke:186 … screenAttribution complete` (the
    ///   media-status attribution finished) are user/app-initiated capture
    ///   evidence. **`…:161 client has entitlement to suppress screen
    ///   indicator` is excluded on purpose** (ruling R15): a live
    ///   Mission-Control-only probe showed it is the only replayd variant
    ///   Mission Control produces, while it never appeared during the probe's
    ///   real capture session — keeping it would make Mission Control notify.
    ///   `hasStarted=0` (the stop) is excluded too: kinds are frozen (R5, no
    ///   "capture stopped") and nothing consumes a stop.
    /// - `screencaptureui` / `screencapture` are mapped only on ScreenCaptureKit
    ///   construction calls (`SCDisplay`/`SCShareableContent`/`SCContentFilter`).
    ///   The same calls appear under a third-party capturer's own
    ///   `processImagePath`, which is how a non-Apple recorder shows up.
    /// - Any process logging under the `com.apple.ScreenCaptureKit` subsystem
    ///   is a capture participant regardless of its name.
    /// - `WindowManager`'s "Change expose mode …" line is Mission Control's
    ///   signal (spec §11-2): the WM's on-screen indicator moment. It carries
    ///   kind `.screenCapture` like the other capture signals; the classifier's
    ///   noise list (`WindowManager`, spec §7) turns it into SYSTEM_NOISE, so
    ///   it is logged and never notified.
    /// - `screensharingd` is the remote-control signal (spec §4/§5). The
    ///   `ScreenCaptureApprovalUI` rule is kept for macOS versions that host
    ///   the approval prompt in its own process (absent from the probe).
    public static let screenCaptureDefaults: [KindRule] = [
        // replayd's capture-session variants (ruling R15; see the bullet list
        // above and the diff evidence in task-12-report.md): `hasStarted=1`
        // starts a session, the `:186` attribution-complete line follows it.
        // The MC echo (`:161 client has entitlement to suppress screen
        // indicator`) and the stops (`hasStarted=0`) deliberately do not
        // match. The `:NNN` markers are this macOS build's log-site numbers
        // from the probe; the matching needles are the message text, which the
        // diff showed is what actually separates the variants.
        KindRule(
            process: "replayd",
            messageContains: ["hasStarted=1", "update screenAttribution complete"],
            kind: .screenCapture
        ),
        KindRule(
            process: "screencaptureui",
            messageContains: ["SCDisplay init", "SCShareableContent", "SCContentFilter"],
            kind: .screenCapture
        ),
        KindRule(
            process: "screencapture",
            messageContains: ["SCDisplay init", "SCShareableContent", "SCContentFilter"],
            kind: .screenCapture
        ),
        KindRule(
            subsystem: "com.apple.ScreenCaptureKit",
            kind: .screenCapture
        ),
        // Mission Control (spec §11-2 / ruling R14). The probe evidence for
        // this needle: 12 matching lines out of 1273 WindowManager lines
        // (0.94%), one per expose-mode enter/exit, message not redacted
        // ("Change expose mode off -> missionControl: gesture(…)",
        // "… missionControl -> off: clientToggle(…)"). Its XPC neighbours
        // (`AdminXPCListener exposeModeDidChange:`, `Windowing mode: …`,
        // `minimumDockRevealAmountDidChange`) stay non-candidates on purpose.
        KindRule(
            process: "WindowManager",
            messageContains: ["Change expose mode"],
            kind: .screenCapture
        ),
        KindRule(
            process: "ScreenCaptureApprovalUI",
            kind: .screenCaptureApproval
        ),
        KindRule(
            process: "screensharingd",
            kind: .remoteControlSession
        ),
    ]

    /// The camera rules (spec §4-D, reworked by the field test of plan T14).
    ///
    /// The plan's `AVCaptureDevice.isInUseByAnotherApplication` poll did not
    /// survive contact with the real machine: Photo Booth's preview, photo and
    /// video capture never flipped that property for the built-in camera, so
    /// the poll was silent for the one thing it existed to catch (the mic poll,
    /// which reads a property that *does* flip, is unaffected). What the camera
    /// does emit reliably is the capture session's own lifecycle line — logged
    /// by **the capturing app's process** under `com.apple.cameracapture`:
    ///
    ///     <<<< AVCaptureSession >>>>
    ///         -[AVCaptureSession_Tundra startRunning]: (0x…) (pthread:0x…)
    ///
    /// A 3956-line probe (predicate = camera-ish processes/subsystems/messages,
    /// recorded while Photo Booth previewed, took a photo, recorded and closed)
    /// showed 544 `com.apple.cameracapture` lines of which **exactly 5** carry
    /// `startRunning`/`stopRunning`: 2 session starts and 3 stops — every other
    /// line is `AVControlCenterModules` / `AVCaptureDALDevice` / session
    /// configuration chatter. The subsystem anchor is what makes the needles
    /// safe: the only other lines in the probe that *mention* the selectors are
    /// CoreMediaIO backtraces (`subsystem com.apple.cmio`, `CMIODeviceStartStream
    /// backtrace … -[AVCaptureSession_Tundra startRunning] + 416`), and they are
    /// deliberately **not** events — same session, milliseconds later, and noise
    /// for anything counting sessions.
    ///
    /// Order inside this list: `startRunning` first, `stopRunning` second; the
    /// two are disjoint by construction (one line carries exactly one selector).
    /// `subsystem` alone is not a rule (`AVControlCenterModules` chatter would
    /// match it), and neither is a needle without the anchor.
    public static let cameraDefaults: [KindRule] = [
        KindRule(
            subsystem: "com.apple.cameracapture",
            messageContains: ["startRunning"],
            kind: .cameraOn
        ),
        KindRule(
            subsystem: "com.apple.cameracapture",
            messageContains: ["stopRunning"],
            kind: .cameraOff
        ),
    ]

    /// The microphone rules (spec §4-E, reworked by the v1.1 field probe).
    ///
    /// macOS exposes no app-level "who is recording" API, but the HAL's own
    /// `coreaudiod` publishes every recorder client's transitions:
    ///
    ///     SystemStatusWrapper.mm:89  SystemStatusWrapper::PublishRecordingClientInfo:
    ///         Report client 15522 running: yes device: <private>
    ///     … running: no …
    ///
    /// PID 15522 was Voice Memos. The same mechanism fires for Teams, Zoom
    /// and any other CoreAudio recorder, so the rule matches on the daemon and
    /// then attributes the event to the client pid named in the message — see
    /// `clientPIDPattern`. The surrounding `coreaudiod` chatter (speaker
    /// volume, IO-engine starts, power assertions) carries no client report
    /// and stays a non-candidate.
    ///
    /// `running: yes` / `running: no` are disjoint: one report line carries
    /// exactly one state. Each rule's `clientPIDPattern` carries its state and
    /// acts as the precise match (the needles above are shared pre-filters),
    /// so the "Updated recording status successfully." sibling — same
    /// function name, no client pid — stays a non-candidate. The on and off
    /// patterns differ only in the trailing state, so they attribute
    /// identically.
    public static let micDefaults: [KindRule] = [
        KindRule(
            process: "coreaudiod",
            messageContains: ["PublishRecordingClientInfo", "running: yes"],
            kind: .micOn,
            clientPIDPattern: KindRule.micStartClientPIDPattern
        ),
        KindRule(
            process: "coreaudiod",
            messageContains: ["PublishRecordingClientInfo", "running: no"],
            kind: .micOff,
            clientPIDPattern: KindRule.micStopClientPIDPattern
        ),
    ]

    /// The client-pid capture group for the start transition:
    /// `Report client 15522 running: yes`.
    static let micStartClientPIDPattern = "Report client ([0-9]+) running: yes"
    /// The client-pid capture group for the stop transition.
    static let micStopClientPIDPattern = "Report client ([0-9]+) running: no"

    /// Every rule the parser ships with, in match order (first match wins).
    ///
    /// Split into the signal-family lists so a caller can reason about one
    /// family at a time; `LogLineParser`'s default is this combined list, so
    /// the shipped parser and the shipped predicate cover the same signals.
    public static let defaults: [KindRule] =
        screenCaptureDefaults + cameraDefaults + micDefaults
}

// MARK: - LogLineParser

/// Turns one line of `/usr/bin/log stream --style ndjson` output into a
/// `RawEvent`, or `nil` when the line is malformed or matches no `KindRule`
/// (spec §4 log-stream watcher; spec §5 precision requirement).
///
/// Tolerant by design — the reader may hand over a line while it is still
/// being written, so nothing here throws or traps:
/// - non-JSON lines (the stream's `Filtering the log data…` preamble, a
///   truncated object) → `nil`
/// - `<private>` / empty `processImagePath` → the actor falls back to the
///   `process` key, then to `"unknown"`; `actorPath` stays `nil`
/// - a line without a parsable `timestamp` → `nil` (every `RawEvent` is
///   stamped)
///
/// Real timestamps look like `2026-10-18 10:30:56.186783+0700` — space
/// separator, six fractional digits, RFC-822 offset — so they need their own
/// formatter, not `ISO8601DateFormatter`.
public struct LogLineParser: Sendable {

    /// Rules tried in order; the first match wins.
    public let rules: [KindRule]

    /// Value the evidence log's `rawSummary` is truncated to (spec §8).
    public static let rawSummaryLimit = 200

    /// Resolver for a rule's `clientPIDPattern` capture: pid → display name
    /// and executable path. Injected so tests never touch the live process
    /// table; production is `LiveProcessNaming.resolve`. `nil` means the
    /// client is gone (or unreadable), and the parser degrades the actor to
    /// the signal itself.
    private let resolveClient: @Sendable (Int32) -> (name: String, path: String?)?

    public init(
        rules: [KindRule] = KindRule.defaults,
        resolveClient: @escaping @Sendable (Int32) -> (name: String, path: String?)? =
            LiveProcessNaming.resolve
    ) {
        self.rules = rules
        self.resolveClient = resolveClient
    }

    /// Parses one ndjson line. `nil` means "not a candidate", never an error.
    public func parse(line: Data) -> RawEvent? {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            return nil
        }
        return parse(object: object)
    }

    /// Convenience for callers that already have the line as a `String`.
    public func parse(line: String) -> RawEvent? {
        parse(line: Data(line.utf8))
    }

    // MARK: - Private

    private static let redactedMarker = "<private>"

    private func parse(object: [String: Any]) -> RawEvent? {
        guard
            let timestampString = Self.string(object, "timestamp"),
            let ts = Self.timestamp(fromLogStream: timestampString)
        else {
            return nil
        }

        // `process` is not emitted by `log stream --style ndjson` (the
        // predicate speaks it, the JSON carries `processImagePath`), but the
        // brief's interface accepts it, so it takes precedence when present.
        let path = Self.usableValue(Self.string(object, "processImagePath"))
        let processKey = Self.usableValue(Self.string(object, "process"))
        let processName = processKey ?? path.map { ($0 as NSString).lastPathComponent }
        let subsystem = Self.string(object, "subsystem")
        let message = Self.string(object, "eventMessage")
            ?? Self.string(object, "formatString")
            ?? ""

        guard let rule = rules.first(where: {
            $0.matches(processName: processName, subsystem: subsystem, message: message)
        }) else {
            return nil
        }

        var actor = processName ?? "unknown"
        var actorPath = path
        var pid = (object["processID"] as? NSNumber)?.int32Value

        if let clientPIDPattern = rule.clientPIDPattern {
            // The line's process is a broker (`coreaudiod`); the actor is the
            // client it names. An unresolvable client is not an error — the
            // stop line routinely arrives after the recorder exited — so the
            // event still lands, attributed to the signal itself. The broker
            // pid must never leak into the event: Kill / Reveal resolve
            // against `pid`, and signalling coreaudiod would be catastrophic.
            if let clientPID = Self.clientPID(in: message, pattern: clientPIDPattern),
               let client = resolveClient(clientPID) {
                actor = client.name
                actorPath = client.path
                pid = clientPID
            } else {
                actor = Self.unattributedMicActor
                actorPath = nil
                pid = nil
            }
        }

        return RawEvent(
            ts: ts,
            source: .logstream,
            kind: rule.kind,
            actor: actor,
            actorPath: actorPath,
            pid: pid,
            rawSummary: message.isEmpty ? nil : String(message.prefix(Self.rawSummaryLimit))
        )
    }

    /// Actor used when a `clientPIDPattern` rule matches but the client cannot
    /// be named. Microphone usage is the only broker-attributed signal today,
    /// so this is the literal `"mic"` — never the broker's name.
    static let unattributedMicActor = "mic"

    /// First capture group of `pattern` in `message`, as a pid.
    ///
    /// The patterns are tiny and the rules that carry one match only on rare
    /// recorder transitions, so compiling per match is cheaper than keeping a
    /// cache next to a value-typed `KindRule`. A malformed pattern or a
    /// non-numeric capture answers `nil`, which the caller treats as
    /// "unattributed".
    private static func clientPID(in message: String, pattern: String) -> Int32? {
        guard
            let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(
                in: message,
                range: NSRange(message.startIndex..., in: message)
            ),
            match.numberOfRanges > 1,
            let range = Range(match.range(at: 1), in: message),
            let pid = Int32(message[range])
        else {
            return nil
        }
        return pid
    }

    /// Non-empty string value for `key`, if the JSON carried one.
    private static func string(_ object: [String: Any], _ key: String) -> String? {
        guard let value = object[key] as? String, !value.isEmpty else { return nil }
        return value
    }

    /// `nil` for values that are absent, empty, or redacted as `<private>`.
    private static func usableValue(_ value: String?) -> String? {
        guard let value, value != redactedMarker else { return nil }
        return value
    }

    /// Parses `yyyy-MM-dd HH:mm:ss.SSSSSSZZZ`, e.g.
    /// `2026-10-18 10:30:56.186783+0700`. Sub-millisecond precision is
    /// truncated by `DateFormatter`; that is accepted (milliseconds are the
    /// spec §8 resolution).
    static func timestamp(fromLogStream string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZZZ"
        return formatter.date(from: string)
    }
}
