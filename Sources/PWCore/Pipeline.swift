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
/// `SYSTEM_NOISE` and `ALLOWLIST` stop after step 1, and the R20 off-events
/// (`cameraOff` / `micOff`, spec §5) stop after step 1 + step 4: logged and
/// fed to the tray, never notified and never bannered.
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
/// | cameraOff / micOff (any tier) | ✅ | ❌ | ❌ | ✅ |
///
/// **Off-events are log-only** (R20, spec §5): `cameraOff` and `micOff` close an
/// observation rather than report a new one, so whatever tier their actor
/// classifies to they stop after `.appendLog` + `.trayUpdate` — no
/// notification, no banner, and no visit to the Throttler (there is nothing to
/// group). The gate sits before the tier switch so pause never changes the
/// outcome either.
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
/// run synchronously in `handle` on that same queue. `setPaused(_:)`,
/// `setClassifier(_:)` and `isPaused` are lock-protected and safe from any
/// thread (the menu action in T17 runs on the main thread), which is why this
/// class is `@unchecked Sendable`.
///
/// **The classifier can be swapped in place** (T23): a config change rebuilds
/// the `Classifier` and hands it to the running pipeline with
/// `setClassifier(_:)`, so a new watchlist entry or allowlist actor takes
/// effect without a relaunch and without touching the `Throttler`'s state. The
/// swap is atomic per event: `handle` reads the current classifier once, so an
/// event is classified wholly by the old or wholly by the new rule set — never
/// by a mix of the two.
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

    /// Tier assignment. Guarded by `lock` so `setClassifier` may run from any
    /// thread while `handle` reads it on the pipeline's own queue.
    private var classifier: Classifier
    private let throttler: Throttler
    private let sink: (Action) -> Void
    private let remoteBannerEnabled: () -> Bool

    // MARK: - Locked state

    /// Guards `classifier` and `paused`. `handle` reads the classifier once at
    /// the top of every event and `paused` once in the NORMAL branch; the menu
    /// (T17) and the config apply (T23) write from the main/watch threads.
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

    // MARK: - Classifier swap

    /// Replaces the tier rules in place (T23's live apply).
    ///
    /// The app calls this after a config change — a Settings save, a watched
    /// file edit, `Reload config` — with a `Classifier` rebuilt from the new
    /// `effective*` lists, and the next event on the pipeline's queue is routed
    /// by it. The swap is lock-protected, so it is safe from the main thread
    /// (and from the config store's queue) while the reader's queue is inside
    /// `handle(_:)`; each event still sees exactly one rule set.
    ///
    /// Nothing else is rebuilt: the `Throttler`'s state, the pause flag and the
    /// sink all belong to the session, not to the config, and a config change
    /// must not open a new notification window for events already grouped.
    public func setClassifier(_ classifier: Classifier) {
        lock.withLock { self.classifier = classifier }
    }

    // MARK: - Handling

    /// Routes one raw event through classification, the evidence log and —
    /// per tier — the throttled notification, banner and tray paths.
    ///
    /// An R20 off-event (`cameraOff` / `micOff`) stops after the log line and
    /// the tray update, whatever its tier.
    ///
    /// Must be called from one serial queue (the Throttler contract); see the
    /// class documentation.
    public func handle(_ raw: RawEvent) {
        // One read: the whole event is classified by whichever rule set was
        // installed at this moment (see `setClassifier`).
        let classifier = lock.withLock { self.classifier }
        let event = classifier.classify(raw)

        // Rule 1: the evidence line is unconditional and first — before any
        // suppression, for every tier.
        sink(.appendLog(event))

        // Rule 2 (R20, spec §5): the off-events close an observation instead
        // of reporting a new one, so they are log-only — the tray list still
        // gets them (the menu's "recent events" is a record, not an alert),
        // but no notification and no banner, whatever tier the actor
        // classifies to. Gating before the tier switch keeps pause out of it
        // too: an off-event behaves identically paused or not.
        if event.event.kind == .cameraOff || event.event.kind == .micOff {
            sink(.trayUpdate(event))
            return
        }

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
