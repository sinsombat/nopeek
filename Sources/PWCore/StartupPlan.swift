import Foundation

// MARK: - StartupPlan

/// The app's startup sequence, as one testable call (plan T24, spec §3/§4).
///
/// `AppController.start()` runs exactly four things, in this order — and the
/// order *is* the contract, because the first two steps fight over the same
/// fact:
///
/// 1. **Read** `EvidenceLog.lastActivity()`. This is the last moment the log
///    still describes the *previous* session.
/// 2. **Append** the boot line (`monitor-started`). From here on the newest
///    line is this launch's, so a check performed later would measure a gap of
///    zero on every launch — the silence it exists to report is exactly the
///    stretch this line ends.
/// 3. **Purge** retention (`EvidenceLog.purgeOldFiles()`, spec §8's startup
///    housekeeping). It runs after the read so the gap is measured against
///    what the log held when the app came back, never against what survived
///    the purge.
/// 4. **Detect** the gap: `GapDetector` with `gapAlertThresholdMinutes`
///    (minutes → seconds) against the instant read in step 1 and `now()`.
///
/// The plan holds no clock and touches no file: the three steps are injected
/// closures and time comes from `now`, so a test can pin the order and any two
/// instants. It returns the gap — `nil` when there is none to report, and on a
/// fresh install where step 1 reads no activity at all — and leaves the
/// response to the app: the `monitor-gap` line, the notification (which
/// bypasses the pipeline, spec §5 monitor-health) and the menu's gap row all
/// belong to the layer that knows about the log, the tiers and the menu.
public struct StartupPlan: Sendable {

    /// Silence longer than this many minutes is a gap (spec §7
    /// `gapAlertThresholdMinutes`, default 15).
    public let gapAlertThresholdMinutes: Int

    private let now: @Sendable () -> Date

    public init(
        gapAlertThresholdMinutes: Int,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.gapAlertThresholdMinutes = gapAlertThresholdMinutes
        self.now = now
    }

    /// Runs the pinned sequence and returns the gap it found.
    ///
    /// - Parameters:
    ///   - lastActivity: step 1's read — the log's newest timestamp, or `nil`
    ///     when the directory holds no log yet.
    ///   - appendMonitorStarted: step 2's write, called exactly once.
    ///   - purgeOldFiles: step 3's housekeeping, called exactly once.
    /// - Returns: the `GapReport` for the silence that preceded this launch, or
    ///   `nil` when there was no last activity or the silence did not exceed
    ///   the threshold (`GapDetector`'s pinned rules: strictly greater, and
    ///   never a negative span).
    public func run(
        lastActivity: () -> Date?,
        appendMonitorStarted: () -> Void,
        purgeOldFiles: () -> Void
    ) -> GapReport? {
        // 1. Read first: a boot line written before this read would erase the
        //    very silence being measured (see the type's documentation).
        let previous = lastActivity()

        // 2. Then the boot line: the app is watching from here on, and the log
        //    says so.
        appendMonitorStarted()

        // 3. Retention, after the read (see the type's documentation).
        purgeOldFiles()

        // 4. The decision, from step 1's value and `now`.
        return GapDetector(threshold: TimeInterval(gapAlertThresholdMinutes) * 60)
            .detect(now: now(), lastActivity: previous)
    }
}
