import Foundation

// MARK: - Action

/// One thing the app layer (T12) should do about an event (spec §5–§6).
///
/// `Pipeline` emits actions in a pinned order for every handled event:
///
/// 1. `.appendLog` — always, and always first, before any suppression. The
///    evidence log records every observation: throttling is grouping, not
///    muting (spec §5), and even a paused NORMAL event leaves a line.
/// 2. `.notify` *or* `.aggregated` — the notification path. Exactly one of
///    the two per notifying event, and only for tiers that notify. `.notify`
///    carries the first event of a throttle window (count 1); `.aggregated`
///    folds a repeat into the running count the notification already shows.
///    A throttled repeat never produces a second `.notify` (plan T11).
/// 3. `.banner` — the red banner (spec §6): per event, ORG always, REMOTE per
///    `bannerOnForRemote`. **Not** throttled here — the Throttler gates
///    `.notify` only; T16's `BannerPolicy` owns the per-actor banner cooldown
///    (`orgBannerCooldownSeconds`). The two controls stay independent.
/// 4. `.trayUpdate` — menu-bar icon / "last 10 events" state (spec §6), for
///    every non-noise tier, pause or no pause.
///
/// `SYSTEM_NOISE` and `ALLOWLIST` stop after step 1.
public enum Action: Equatable, Sendable {
    case appendLog(ClassifiedEvent)
    case notify(ClassifiedEvent)
    case banner(ClassifiedEvent)
    case trayUpdate(ClassifiedEvent)
    case aggregated(ClassifiedEvent, count: Int)
}

// MARK: - Pipeline

/// Turns every `RawEvent` into the ordered list of `Action`s the app layer
/// executes (spec §5–§6, plan T11).
///
/// **Routing table** (all five tiers; the order below is the emission order):
///
/// | Tier | appendLog | notify / aggregated | banner | trayUpdate |
/// |---|---|---|---|---|
/// | ORG | ✅ | ✅ (throttled) | ✅ | ✅ |
/// | REMOTE | ✅ | ✅ (throttled) | ✅ per `remoteBannerEnabled()` | ✅ |
/// | NORMAL | ✅ | ✅ unless paused (throttled) | ❌ | ✅ always |
/// | SYSTEM_NOISE / ALLOWLIST | ✅ | ❌ | ❌ | ❌ |
///
/// **Notifications are throttled, banners are not.** The notification path is
/// the only one that touches the `Throttler`: `Decision.notify(e)` becomes
/// `.notify(e)`, `Decision.aggregated(count:)` becomes
/// `.aggregated(the event passed in, count:)`. `.banner` is emitted per event
/// — T16's `BannerPolicy` applies the 60 s banner cooldown — so the pipeline
/// never double-throttles a banner behind the notification window.
///
/// **Pause** suppresses exactly the NORMAL notification, nothing else: ORG and
/// REMOTE still notify and banner (spec §5 — "Pause: ระงับเฉพาะ tier NORMAL"),
/// and NORMAL events keep reaching the log and the tray. While paused the
/// NORMAL notification path does not consult the `Throttler` at all: a window
/// opened by a notification that was never shown would make the first event
/// after unpause read as an aggregate of a notification the user never saw,
/// so unpausing notifies fresh on the next event.
///
/// **Threading.** `Throttler` is not thread-safe (T7), so `handle(_:)` must be
/// called from **one serial queue** — in the app that is the log-stream
/// reader's callback queue (T12). The sink and `remoteBannerEnabled` closures
/// run synchronously in `handle` on that same queue. `setPaused(_:)` and
/// `isPaused` are lock-protected and safe from any thread (the menu action in
/// T17 runs on the main thread), which is why this class is
/// `@unchecked Sendable`.
///
/// **Performance** (Review Focus #5): one classify, at most four sink calls
/// and one O(1) throttler step per event; a 10,000-event burst stays well
/// under the 1 s budget (`PipelineTests.testBurstKeepsProcessingUnder1s`).
public final class Pipeline: @unchecked Sendable {

    /// The plan spells T12 call sites as `Pipeline.Action.trayUpdate`. The
    /// enum itself lives at module scope to match the flat naming of the
    /// other core types (`ClassifiedEvent`, `GapReport`); this alias keeps
    /// that spelling valid too.
    public typealias Action = PWCore.Action

    // MARK: - Dependencies

    private let classifier: Classifier
    private let throttler: Throttler
    private let sink: (Action) -> Void
    private let remoteBannerEnabled: () -> Bool

    // MARK: - Pause state

    /// Guards `paused`. `handle` reads it once per NORMAL event; the menu
    /// (T17) writes it from the main thread.
    private let lock = NSLock()
    private var paused = false

    /// Whether NORMAL notifications are currently suppressed. The tray icon
    /// (T17) reads this back to show the ⏸️ state.
    public var isPaused: Bool {
        lock.withLock { paused }
    }

    // MARK: - Life cycle

    /// - Parameters:
    ///   - classifier: tier assignment (spec §5).
    ///   - throttler: 60 s notification grouping. Not thread-safe — see the
    ///     class documentation for the single-queue contract.
    ///   - sink: receives every action, in order, synchronously.
    ///   - remoteBannerEnabled: read live per REMOTE event, so the app layer
    ///     can point it straight at `configStore.config.bannerOnForRemote`
    ///     and have a runtime config reload take effect immediately.
    public init(
        classifier: Classifier,
        throttler: Throttler,
        sink: @escaping (Action) -> Void,
        remoteBannerEnabled: @escaping () -> Bool
    ) {
        self.classifier = classifier
        self.throttler = throttler
        self.sink = sink
        self.remoteBannerEnabled = remoteBannerEnabled
    }

    // MARK: - Pause

    /// Suppresses (or resumes) NORMAL notifications only. ORG, REMOTE, the
    /// evidence log and the tray are unaffected.
    public func setPaused(_ paused: Bool) {
        lock.withLock { self.paused = paused }
    }

    // MARK: - Handling

    /// Routes one raw event through classification, the evidence log and —
    /// per tier — the throttled notification, banner and tray paths.
    ///
    /// Must be called from one serial queue (the Throttler contract); see the
    /// class documentation.
    public func handle(_ raw: RawEvent) {
        let event = classifier.classify(raw)

        // Rule 1: the evidence line is unconditional and first — before any
        // suppression, for every tier.
        sink(.appendLog(event))

        switch event.tier {
        case .org:
            // Never suppressed: neither pause nor anything else mutes ORG.
            emitNotification(for: event)
            sink(.banner(event))
            sink(.trayUpdate(event))

        case .remote:
            // Not suppressed by pause either (spec §5).
            emitNotification(for: event)
            if remoteBannerEnabled() {
                sink(.banner(event))
            }
            sink(.trayUpdate(event))

        case .normal:
            // Pause skips the notify path *including its throttler
            // bookkeeping*; the tray keeps updating either way.
            if !lock.withLock({ paused }) {
                emitNotification(for: event)
            }
            sink(.trayUpdate(event))

        case .systemNoise, .allowlist:
            // Logged above; never notified, never bannered, never trayed.
            break
        }
    }

    /// The throttled notification path: exactly one of `.notify` /
    /// `.aggregated` per call, never both, never a second `.notify` for a
    /// repeat inside a window.
    private func emitNotification(for event: ClassifiedEvent) {
        switch throttler.process(event) {
        case .notify(let first):
            sink(.notify(first))
        case .aggregated(let count):
            sink(.aggregated(event, count: count))
        }
    }
}
