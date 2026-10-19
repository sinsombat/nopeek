import Foundation

// MARK: - GapReport

/// One unexplained silence in monitoring: from the last evidence the log
/// holds to the moment the app came back and asked (spec §4, plan T9).
///
/// `from` is the `lastActivity` the caller passed in, `to` the `now` it
/// passed in, and `duration` their exact difference — the report never
/// rounds or clamps, so the menu string (T17) and the `monitor-gap` log line
/// (T24) both carry the real span.
public struct GapReport: Equatable, Sendable {
    /// Timestamp of the last known activity (last log line or heartbeat).
    public var from: Date
    /// When the check ran.
    public var to: Date
    /// `to - from`, in seconds. Never negative on a report that exists.
    public var duration: TimeInterval

    public init(from: Date, to: Date, duration: TimeInterval) {
        self.from = from
        self.to = to
        self.duration = duration
    }
}

// MARK: - GapDetector

/// Decides whether the monitor was off long enough to deserve a warning
/// (spec §4 monitor-gap, plan T9).
///
/// At startup (T24) the app hands the detector `lastActivity()` from the
/// evidence log and the current time; a silent stretch longer than the
/// configured threshold (`gapAlertThresholdMinutes`, default 15 minutes —
/// spec §7) means the machine was asleep, shut down, or the app was not
/// running, and the status item must say so rather than read as "all clear".
///
/// The detector is pure arithmetic over its arguments — it holds no clock and
/// reads no file, so a test (or the app) can pin any two instants and get the
/// same answer. The rule is strict and pinned by `GapDetectorTests`:
///
/// - no `lastActivity` at all (fresh install, empty log) → `nil`;
/// - `duration <= threshold` → `nil`; silence *at* the threshold does not
///   count, only silence beyond it (spec §4: "gap > gapAlertThresholdMinutes");
/// - negative `duration` (`now` before `lastActivity`, i.e. the clock moved
///   backwards under us) → `nil`, never a negative or otherwise absurd
///   report (Review Focus #4);
/// - otherwise a `GapReport` spanning exactly `lastActivity … now`.
///
/// A negative `threshold` is not specially defended beyond the
/// negative-duration guard; configuration supplies it in whole minutes ≥ 1.
public struct GapDetector: Sendable {

    /// Silence counts as a gap only when it is strictly longer than this, in
    /// seconds.
    public let threshold: TimeInterval

    public init(threshold: TimeInterval) {
        self.threshold = threshold
    }

    /// The gap `now` sits at the end of, or `nil` when there is none to
    /// report. See the type documentation for the exact boundary rules.
    public func detect(now: Date, lastActivity: Date?) -> GapReport? {
        guard let from = lastActivity else { return nil }

        let duration = now.timeIntervalSince(from)
        // The `duration >= 0` guard is redundant for any realistic
        // (non-negative) threshold, where `duration > threshold` already
        // excludes negatives; it stays explicit so a backwards clock can
        // never slip through on a negative threshold.
        guard duration > threshold, duration >= 0 else { return nil }

        return GapReport(from: from, to: now, duration: duration)
    }
}
