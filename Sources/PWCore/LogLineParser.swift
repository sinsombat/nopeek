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
/// ⌘⇧5 screenshot toolbar + Mission Control, 2181 lines): precision first, so
/// XPC/prefs chatter from `screencaptureui` and Mission Control window
/// bookkeeping from `WindowManager` produce no candidates.
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

    public init(
        process: String? = nil,
        subsystem: String? = nil,
        messageContains: [String]? = nil,
        kind: EventKind
    ) {
        self.process = process
        self.subsystem = subsystem
        self.messageContains = messageContains
        self.kind = kind
    }

    /// A rule needs a process or subsystem anchor to be a signal.
    var isAnchored: Bool {
        process != nil || subsystem != nil
    }

    func matches(processName: String?, subsystem candidateSubsystem: String?, message: String) -> Bool {
        guard isAnchored else { return false }
        if let process, process != processName { return false }
        if let subsystem, subsystem != candidateSubsystem { return false }
        guard let messageContains, !messageContains.isEmpty else { return true }
        return messageContains.contains { message.contains($0) }
    }
}

extension KindRule {

    /// The shipped capture rules, ordered by specificity (first match wins).
    ///
    /// - `replayd` + `updateScreenCaptureDidStart` is the screen-capture
    ///   *truth* signal on this machine: replayed is the indicator owner and
    ///   logs when a capture session starts (the probe's line also notes
    ///   whether the client may suppress the purple indicator — that stays in
    ///   `rawSummary` for the evidence log, it is not a separate kind).
    /// - `screencaptureui` / `screencapture` are mapped only on ScreenCaptureKit
    ///   construction calls (`SCDisplay`/`SCShareableContent`/`SCContentFilter`).
    ///   The same calls appear under a third-party capturer's own
    ///   `processImagePath`, which is how a non-Apple recorder shows up.
    /// - Any process logging under the `com.apple.ScreenCaptureKit` subsystem
    ///   is a capture participant regardless of its name.
    /// - `screensharingd` is the remote-control signal (spec §4/§5). The
    ///   `ScreenCaptureApprovalUI` rule is kept for macOS versions that host
    ///   the approval prompt in its own process (absent from the probe).
    public static let screenCaptureDefaults: [KindRule] = [
        KindRule(
            process: "replayd",
            messageContains: ["updateScreenCaptureDidStart"],
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
        KindRule(
            process: "ScreenCaptureApprovalUI",
            kind: .screenCaptureApproval
        ),
        KindRule(
            process: "screensharingd",
            kind: .remoteControlSession
        ),
    ]
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

    public init(rules: [KindRule] = KindRule.screenCaptureDefaults) {
        self.rules = rules
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

        return RawEvent(
            ts: ts,
            source: .logstream,
            kind: rule.kind,
            actor: processName ?? "unknown",
            actorPath: path,
            pid: (object["processID"] as? NSNumber)?.int32Value,
            rawSummary: message.isEmpty ? nil : String(message.prefix(Self.rawSummaryLimit))
        )
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
