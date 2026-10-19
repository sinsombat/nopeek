import Foundation

// MARK: - Tier

/// Severity tier assigned by the Classifier (spec §5).
///
/// Raw values are the literal strings written to the evidence log (spec §8);
/// they are part of the on-disk format and must not be renamed.
public enum Tier: String, Codable, CaseIterable, Equatable, Sendable {
    /// Org / RMM / remote-management pattern matched an actor (highest priority, cannot be muted).
    case org = "ORG"
    /// Remote-control actor from the watchlist.
    case remote = "REMOTE"
    /// Anything not otherwise classified.
    case normal = "NORMAL"
    /// macOS's own window-management chatter (logged, never notified).
    case systemNoise = "SYSTEM_NOISE"
    /// Actor the user explicitly trusts.
    case allowlist = "ALLOWLIST"
}

// MARK: - EventKind

/// What was observed (spec §8).
public enum EventKind: String, Codable, Equatable, Sendable {
    case screenCapture = "screen-capture"
    case screenCaptureApproval = "screen-capture-approval"
    case remoteControlProcess = "remote-control-process"
    case remoteControlSession = "remote-control-session"
    case cameraOn = "camera-on"
    case cameraOff = "camera-off"
    case micOn = "mic-on"
    case micOff = "mic-off"
    case monitorStarted = "monitor-started"
    case monitorDegraded = "monitor-degraded"
    case monitorRecovered = "monitor-recovered"
    case monitorGap = "monitor-gap"
    case configReloaded = "config-reloaded"
    case calibrationResult = "calibration-result"
    case checkupRun = "checkup-run"
    case exportCreated = "export-created"
    /// One kill attempt (manual or auto) — spec §6d/§8. The `rawSummary` of the
    /// line carries the outcome.
    case processKill = "process-kill"
    case heartbeat = "heartbeat"
}

// MARK: - EventSource

/// Which watcher produced a `RawEvent`.
public enum EventSource: String, Codable, Equatable, Sendable {
    case logstream = "logstream"
    case processwatch = "processwatch"
    case camera = "camera"
    case mic = "mic"
    case system = "system"
}

// MARK: - Timestamp coding

/// Spec §8 timestamps: ISO8601 with millisecond precision and an explicit UTC
/// offset, e.g. `2026-10-17T15:04:05.123+07:00`.
///
/// Formatters are created per call: `ISO8601DateFormatter` is not `Sendable`,
/// and this is not a hot path (tens of events per second at most).
enum ISO8601Timestamp {
    static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    static func date(from string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)
    }
}

// MARK: - RawEvent

/// One observation as produced by a watcher, before classification (spec §3).
public struct RawEvent: Codable, Equatable, Sendable {
    /// When the log line / poll observed the event.
    public var ts: Date
    /// Which watcher produced it.
    public var source: EventSource
    public var kind: EventKind
    /// Process or subsystem that caused the event, e.g. `screencaptureui`.
    public var actor: String
    /// Executable path when the log line exposed it (may be redacted as `<private>`).
    public var actorPath: String?
    public var pid: Int32?
    /// Short excerpt of the underlying log line (truncated to 200 chars).
    public var rawSummary: String?

    public init(
        ts: Date,
        source: EventSource,
        kind: EventKind,
        actor: String,
        actorPath: String? = nil,
        pid: Int32? = nil,
        rawSummary: String? = nil
    ) {
        self.ts = ts
        self.source = source
        self.kind = kind
        self.actor = actor
        self.actorPath = actorPath
        self.pid = pid
        self.rawSummary = rawSummary
    }

    enum CodingKeys: String, CodingKey {
        case ts, source, kind, actor, actorPath, pid, rawSummary
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let ts = try container.decode(String.self, forKey: .ts)
        guard let date = ISO8601Timestamp.date(from: ts) else {
            throw DecodingError.dataCorruptedError(
                forKey: .ts,
                in: container,
                debugDescription: "expected ISO8601 timestamp with milliseconds, got \"\(ts)\""
            )
        }
        self.ts = date
        self.source = try container.decode(EventSource.self, forKey: .source)
        self.kind = try container.decode(EventKind.self, forKey: .kind)
        self.actor = try container.decode(String.self, forKey: .actor)
        self.actorPath = try container.decodeIfPresent(String.self, forKey: .actorPath)
        self.pid = try container.decodeIfPresent(Int32.self, forKey: .pid)
        self.rawSummary = try container.decodeIfPresent(String.self, forKey: .rawSummary)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ISO8601Timestamp.string(from: ts), forKey: .ts)
        try container.encode(source, forKey: .source)
        try container.encode(kind, forKey: .kind)
        try container.encode(actor, forKey: .actor)
        try container.encodeIfPresent(actorPath, forKey: .actorPath)
        try container.encodeIfPresent(pid, forKey: .pid)
        try container.encodeIfPresent(rawSummary, forKey: .rawSummary)
    }
}

// MARK: - ClassifiedEvent

/// A `RawEvent` plus the tier and reason assigned by the Classifier (spec §5).
///
/// Codable is flat on purpose: one `ClassifiedEvent` is one evidence-log line
/// with the spec §8 schema (`ts`, `source`, `kind`, …, `tier`, `reason`,
/// `count`), not a nested `{"event": {…}, "tier": …}` object. Because `RawEvent`
/// encodes `ts` itself, the ISO8601 timestamp coding applies here too.
public struct ClassifiedEvent: Codable, Equatable, Sendable {
    public var event: RawEvent
    public var tier: Tier
    /// Why the tier was chosen: `orgPattern:<pattern>` | `system-noise` |
    /// `allowlist` | `remote-control` | `default`.
    public var reason: String
    /// Number of identical events collapsed into this one by the Throttler (≥ 1).
    public var count: Int

    public init(event: RawEvent, tier: Tier, reason: String, count: Int = 1) {
        self.event = event
        self.tier = tier
        self.reason = reason
        self.count = count
    }

    enum CodingKeys: String, CodingKey {
        case tier, reason, count
    }

    public func encode(to encoder: Encoder) throws {
        try event.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tier, forKey: .tier)
        try container.encode(reason, forKey: .reason)
        try container.encode(count, forKey: .count)
    }

    public init(from decoder: Decoder) throws {
        self.event = try RawEvent(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.tier = try container.decode(Tier.self, forKey: .tier)
        self.reason = try container.decode(String.self, forKey: .reason)
        self.count = try container.decode(Int.self, forKey: .count)
    }
}
