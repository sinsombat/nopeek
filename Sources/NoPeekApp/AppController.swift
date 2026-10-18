import Foundation

import PWCore

// MARK: - AppController

/// NoPeek's single wiring point (plan T12): it owns one instance of every
/// core component, turns `Pipeline` actions into real side effects, and holds
/// the state later tasks build on (T13–T21).
///
/// **Construction** (`AppController.shared`, main thread):
/// `ConfigStore(~/.config/nopeek/config.json)` → `EvidenceLog(~/Library/Logs/NoPeek)`
/// → `Classifier` (built once from the config's effective lists) →
/// `Throttler(60 s)` → `Pipeline` → `LogStreamReader` (default ndjson command
/// + default predicate). The `Classifier` is a *snapshot*: T17 adds the config
/// watcher and rebuilds it on change — live reload is not wired yet, and the
/// `ConfigStore` is deliberately not started.
///
/// **Startup order** (`start()`): the `monitor-started` lifecycle line first,
/// then the reader. T21 wraps this with retention purge, the gap check and the
/// heartbeat timer.
///
/// **Threading.** The reader delivers lines and state transitions on its one
/// serial callback queue; `Pipeline` (and the `Throttler` inside it) require
/// exactly that. The sink therefore also runs on that queue: `EvidenceLog` is
/// driven by one owner, and the only state the main thread shares with it — the
/// tray and the reader state — sits behind `uiLock`. Notifications are posted
/// on the main actor.
final class AppController: @unchecked Sendable {

    // MARK: - Shared instance

    /// The app's controller. Creating one builds `NotificationService`, so the
    /// whole app must share this instance — two of them would fight over the
    /// `UNUserNotificationCenter` delegate.
    @MainActor static let shared = AppController()

    // MARK: - Paths

    /// `~/.config/nopeek/config.json` (spec §7).
    static var defaultConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/nopeek/config.json")
    }

    /// `~/Library/Logs/NoPeek` (spec §8) — not a TCC-protected location.
    static var defaultLogDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/NoPeek")
    }

    // MARK: - Components

    /// Spec §7 config; loaded at construction, watched from T17 on.
    let configStore: ConfigStore
    /// Spec §8 evidence log, one `events-YYYY-MM-DD.ndjson` per day.
    let evidenceLog: EvidenceLog
    /// Notification delivery (spec §6); the app's only permission.
    let notifications: NotificationService

    /// The routing pipeline (T11). Built on first use — it captures `self` —
    /// from `start()` on the main thread, before any callback can touch it.
    private(set) lazy var pipeline: Pipeline = Pipeline(
        classifier: classifier,
        throttler: throttler,
        sink: { [weak self] action in self?.perform(action) },
        // Read live per REMOTE event, so a future config reload takes effect
        // without rebuilding the pipeline (spec §7).
        remoteBannerEnabled: { [weak self] in self?.configStore.config.bannerOnForRemote ?? false }
    )

    /// The `log stream` child (T5) with its default predicate — which already
    /// includes `process == "WindowManager"` for Mission Control.
    private(set) lazy var reader: LogStreamReader = LogStreamReader(
        onLine: { [weak self] line in self?.consume(line) },
        onState: { [weak self] state in self?.readerStateChanged(state) }
    )

    /// Snapshot of the classifier lists, built once from the config loaded in
    /// `init` (T17 rebuilds it when a change lands).
    private let classifier: Classifier
    private let throttler: Throttler
    private let parser: LogLineParser

    // MARK: - Shared state

    /// Guards `tray`, `logStreamState` and `started`: the sink and the reader's
    /// state callback write them off the reader queue, the status menu (T17)
    /// reads them on the main thread.
    private let uiLock = NSLock()
    private var tray = TrayModel()
    private var readerStateValue: LogStreamReader.State?
    private var started = false

    // MARK: - Init

    @MainActor
    private init() {
        let notifications = NotificationService()
        self.notifications = notifications

        let configStore = ConfigStore(url: Self.defaultConfigURL, onChange: { _ in })
        configStore.load()
        self.configStore = configStore

        self.classifier = Classifier(
            org: configStore.config.effectiveOrgPatterns,
            noise: configStore.config.effectiveSystemNoise,
            allowlist: configStore.config.allowlist,
            remote: configStore.config.effectiveRemoteControl
        )
        self.throttler = Throttler()

        // Retention is the configured value already so T21's `purgeOldFiles()`
        // honours spec §7 without re-reading the config.
        self.evidenceLog = EvidenceLog(
            directory: Self.defaultLogDirectory,
            retentionDays: configStore.config.logRetentionDays
        )
        self.parser = LogLineParser()
    }

    // MARK: - Life cycle

    /// Records the boot and starts watching (spec §3: every boot leaves a
    /// `monitor-started` line). Idempotent.
    func start() {
        let shouldStart = uiLock.withLock { () -> Bool in
            guard !started else { return false }
            started = true
            return true
        }
        guard shouldStart else { return }

        evidenceLog.appendRaw(kind: .monitorStarted)
        reader.start()
    }

    /// Stops the reader and terminates its child, so quitting the app never
    /// leaves an orphaned `log stream` behind. Safe to call when not started.
    func stop() {
        reader.stop()
    }

    // MARK: - State for the status menu (T17)

    /// The tray's newest-first events, at most `TrayModel.capacity` (spec §6).
    var recentEvents: [ClassifiedEvent] {
        uiLock.withLock { tray.events }
    }

    /// The reader's last reported state; `nil` before `start()`. T17 renders
    /// the degraded icon from this.
    var logStreamState: LogStreamReader.State? {
        uiLock.withLock { readerStateValue }
    }

    // MARK: - Pipeline sink

    /// Executes one `Pipeline` action. Runs on the reader's serial callback
    /// queue, in emission order (see the class note on threading).
    private func perform(_ action: Action) {
        switch action {
        case .appendLog(let event):
            evidenceLog.append(event)

        case .notify(let event):
            postNotification(for: event)

        case .banner:
            // T16 owns this: `BannerPolicy` (per-actor 60 s cooldown) plus
            // `BannerPresenter`. Until then no banner is shown — an ORG banner
            // without its cooldown would repeat on every event of a burst.
            break

        case .trayUpdate(let event):
            uiLock.withLock { tray.record(event) }

        case .aggregated(let event, let count):
            // Folded into the row the notification window opened — never a new
            // row and never a second notification (spec §5).
            uiLock.withLock { tray.applyAggregate(event, count: count) }
        }
    }

    /// Posts the tier's notification on the main actor (`NotificationService`
    /// is `@MainActor`). Copy comes from `Strings` in the configured language
    /// (spec §6/§10) — title and body per tier, with actor + kind in the body —
    /// and the thread id groups per tier (R10).
    private func postNotification(for event: ClassifiedEvent) {
        let language = Language(rawValue: configStore.config.language) ?? Strings.defaultLanguage
        guard let copy = Strings.notificationCopy(for: event, language: language) else { return }

        let tier = event.tier
        let notifications = self.notifications

        Task { @MainActor in
            notifications.post(
                title: copy.title,
                body: copy.body,
                threadID: NotificationService.threadID(for: tier)
            )
        }
    }

    // MARK: - Reader callbacks

    /// One ndjson line from the reader: parse, then route. Lines that match no
    /// rule are skipped without ceremony (T4 precision).
    private func consume(_ line: Data) {
        guard let raw = parser.parse(line: line) else { return }
        pipeline.handle(raw)
    }

    /// Reader state transitions: kept for the menu icon (T17) and written to
    /// the evidence log (spec §3). Every `.degraded` is one child death, so
    /// each is recorded; `monitor-recovered` is written only for a real
    /// `.degraded → .running` recovery — the first `.running` of a boot is not
    /// a recovery, `monitor-started` already covers it.
    private func readerStateChanged(_ state: LogStreamReader.State) {
        let previous = uiLock.withLock { () -> LogStreamReader.State? in
            let previous = readerStateValue
            readerStateValue = state
            return previous
        }

        switch (previous, state) {
        case (_, .degraded):
            evidenceLog.appendRaw(kind: .monitorDegraded)
        case (.degraded, .running):
            evidenceLog.appendRaw(kind: .monitorRecovered)
        default:
            break
        }
    }
}
