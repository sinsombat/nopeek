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
/// `Throttler(60 s)` → `Pipeline` → `BannerPolicy` + `BannerPresenter` (T16: the
/// red banner's per-actor cooldown and its non-activating panels) →
/// `LogStreamReader` (default ndjson command
/// + default predicate) → `ProcessWatch` (T13: the remote-tier process table
/// watch, whose watchlist closure reads `config` live) → `MicWatch` (T15: the
/// 2 s microphone poll). Camera detection needs no component of its own: the
/// T14 field-test fix moved it onto the log stream (the parser's
/// `KindRule.cameraDefaults` + the predicate's camera clauses). The
/// `Classifier` is a *snapshot*: T17 adds the config watcher and rebuilds it on
/// change — live reload is not wired yet, and the `ConfigStore` is deliberately
/// not started.
///
/// **Startup order** (`start()`): the `monitor-started` lifecycle line first,
/// then the reader, then the process watch (T13: a 3 s `DispatchSourceTimer`
/// whose polls run on the reader's serial queue, so `tick()` and
/// `pipeline.handle(_:)` serialize with log lines) and the mic watch (T15: the
/// same shape at 2 s). T21 wraps this with retention purge, the gap check and
/// the heartbeat timer.
///
/// **Threading.** The reader delivers lines and state transitions on its one
/// serial callback queue; `Pipeline` (and the `Throttler` inside it) require
/// exactly that. The process watch (T13) and the mic watch (T15) deliver their
/// polls on the same queue (`LogStreamReader.performSerialized`), so the
/// pipeline has one owner. The sink therefore also runs on that queue:
/// `EvidenceLog` is driven by one owner, `BannerPolicy.shouldShow` keeps its
/// per-actor cooldown ordered there too, and the only state the main thread
/// shares with it — the tray and the reader state — sits behind `uiLock`.
/// Notifications and banners are then posted on the main actor.
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

    /// The remote tier's process watch (T13, spec §4-B): one 3 s poll of the
    /// process table against the config's remote-control watchlist.
    private let processWatch: ProcessWatch

    // The camera needs no component here (T14 field-test fix, spec §4-D): its
    // signal arrives over the log stream like any other — see the class
    // documentation and `KindRule.cameraDefaults`.

    /// The mic watch (T15, spec §4-E): one 2 s poll of the audio devices that
    /// have input streams and are running. Reads device properties only — no
    /// IO, no TCC request API (spec §3).
    private let micWatch: MicWatch

    /// The red banner's per-actor cooldown (T16, spec §5). Built once from the
    /// config `init` loaded, like the `Classifier` snapshot: T17's live reload
    /// rebuilds it when `orgBannerCooldownSeconds` changes.
    private let bannerPolicy: BannerPolicy

    /// The red banner itself (T16, spec §6): a non-activating panel per screen.
    /// Reads `bannerLevel` live on every show, so a reload changes the next
    /// banner without rebuilding this.
    private let bannerPresenter: BannerPresenter

    /// Fires the process-watch polls. The poll body itself is delivered on the
    /// reader's serial queue (see `startProcessWatch`); this queue only holds
    /// the timer, so a busy main thread never delays a poll.
    private let processWatchQueue = DispatchQueue(label: "com.sinsombat.nopeek.processwatch")
    /// Armed by `start()`, cancelled by `stop()`.
    private var processWatchTimer: DispatchSourceTimer?

    /// Fires the mic-watch polls (T15); same division of labour as the
    /// process-watch queue above.
    private let micWatchQueue = DispatchQueue(label: "com.sinsombat.nopeek.micwatch")
    private var micWatchTimer: DispatchSourceTimer?

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

        // The watchlist is read from the store on every tick, so T17's config
        // reload takes effect without rebuilding anything here. Capturing the
        // local store (not `self`) keeps the closure out of the init cycle.
        self.processWatch = ProcessWatch(
            names: { configStore.config.effectiveRemoteControl }
        )

        // The camera is log-driven (no watch object to build); the mic watch
        // (T15) reads whether an input device is running and reports the
        // on/off edges.
        self.micWatch = MicWatch()

        // The banner gate (T16, spec §5): `Pipeline` emits `.banner` for every
        // eligible event; this policy decides whether one shows, per actor.
        self.bannerPolicy = BannerPolicy(
            cooldown: TimeInterval(configStore.config.orgBannerCooldownSeconds)
        )

        // `bannerLevel` is read live per show (spec §7), so it reads the local
        // store rather than capturing `self`.
        self.bannerPresenter = BannerPresenter(
            windowLevel: { BannerPresenter.windowLevel(forBannerLevel: configStore.config.bannerLevel) },
            logDirectoryURL: Self.defaultLogDirectory
        )
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
        startProcessWatch()
        startMicWatch()
    }

    /// Stops the reader and terminates its child, so quitting the app never
    /// leaves an orphaned `log stream` behind. Safe to call when not started.
    func stop() {
        stopProcessWatch()
        stopMicWatch()
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

        case .banner(let event):
            // T16: the policy owns the per-actor cooldown (spec §5). A
            // suppressed repeat is silent *here only* — `.appendLog`, the
            // notification path and `.trayUpdate` above/below already ran and
            // are never affected. The decision happens on this serial queue,
            // so cooldown ordering is emission ordering.
            guard bannerPolicy.shouldShow(event) else { break }
            presentBanner(for: event)

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

    /// Puts the red banner on screen (T16, spec §6). Same hop as
    /// `postNotification`: `BannerPresenter` is AppKit and main-actor-isolated,
    /// while `perform` runs on the reader's serial queue — the policy decision
    /// itself already happened there, synchronously, in emission order.
    private func presentBanner(for event: ClassifiedEvent) {
        let language = Language(rawValue: configStore.config.language) ?? Strings.defaultLanguage
        let presenter = bannerPresenter

        Task { @MainActor in
            presenter.show(
                tier: event.tier,
                actor: event.event.actor,
                kind: event.event.kind.rawValue,
                lang: language
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

    // MARK: - Process watch (T13)

    /// Poll cadence (spec §3: every 3 s).
    private static let processWatchInterval: TimeInterval = 3

    /// Arms the process-watch timer (spec §3/§4-B). Idempotent.
    ///
    /// The timer fires on `processWatchQueue`, and every poll hands its work
    /// to the reader's serial queue: `ProcessWatch.tick()` and
    /// `Pipeline.handle(_:)` then serialize with log lines, which is the
    /// single-owner contract of the non-thread-safe `Throttler` and
    /// `EvidenceLog` (T7/T11). The reader is captured here, on the main
    /// thread, after `start()` has built it.
    private func startProcessWatch() {
        guard processWatchTimer == nil else { return }

        let reader = self.reader
        let timer = DispatchSource.makeTimerSource(queue: processWatchQueue)
        // First poll immediately: a remote-control process that was already
        // running at boot is worth knowing about, and it is logged as an
        // appearance exactly like a later one. (Nothing re-fires until it
        // leaves the table and comes back — the T13 edge rule.)
        timer.schedule(deadline: .now(), repeating: Self.processWatchInterval)
        timer.setEventHandler { [weak self] in
            reader.performSerialized { [weak self] in
                guard let self else { return }
                // `tick()` reads the watchlist from the live config, lists
                // the process table once, and returns one event per watched
                // name that just appeared. From here on the events are
                // routed exactly like log-stream ones (classify → log →
                // notify / banner / tray).
                for raw in self.processWatch.tick() {
                    self.pipeline.handle(raw)
                }
            }
        }
        processWatchTimer = timer
        timer.resume()
    }

    /// Cancels the polls. A poll already delivered to the reader's queue may
    /// still run once (see `performSerialized`); that single tick is harmless
    /// — the app is terminating, and the line it may append is a true
    /// observation.
    private func stopProcessWatch() {
        processWatchTimer?.cancel()
        processWatchTimer = nil
    }

    // MARK: - Mic watch (T15)

    /// Arms the mic-watch timer (spec §3/§4-E). Idempotent.
    ///
    /// Same structure as the process and camera watches: the timer fires on its
    /// own queue and hands each poll to the reader's serial queue, so
    /// `MicWatch.tick()` and `Pipeline.handle(_:)` serialize with log lines and
    /// with the other two watches' polls. The cadence comes from the watch
    /// itself (`micWatch.interval`, pinned at 2 s) rather than a second
    /// constant here, so the poller and its timer cannot drift apart.
    ///
    /// The first poll is immediate: a microphone already in use when NoPeek
    /// starts is worth knowing about — that is exactly the state a user checks
    /// for — and it is reported like any later one.
    private func startMicWatch() {
        guard micWatchTimer == nil else { return }

        let reader = self.reader
        let timer = DispatchSource.makeTimerSource(queue: micWatchQueue)
        timer.schedule(deadline: .now(), repeating: micWatch.interval)
        timer.setEventHandler { [weak self] in
            reader.performSerialized { [weak self] in
                guard let self else { return }
                // `tick()` reads the system mic state and returns an event only
                // on an edge: `micOn` the first time an input device is seen
                // running, `micOff` once it has been down for longer than the
                // 5 s debounce. From here on the event is routed exactly like a
                // log-stream one (classify → log → notify / banner / tray);
                // with actor "mic" it classifies NORMAL by default, which is
                // the tier the user can mute.
                guard let raw = self.micWatch.tick() else { return }
                self.pipeline.handle(raw)
            }
        }
        micWatchTimer = timer
        timer.resume()
    }

    /// Cancels the mic polls; the same one-tick grace as `stopProcessWatch`.
    private func stopMicWatch() {
        micWatchTimer?.cancel()
        micWatchTimer = nil
    }
}
