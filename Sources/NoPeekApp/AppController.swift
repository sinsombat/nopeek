import Foundation

import PWCore

// MARK: - AppController

/// NoPeek's single wiring point (plan T12): it owns one instance of every
/// core component, turns `Pipeline` actions into real side effects, and holds
/// the state later tasks build on (T13–T21).
///
/// **Construction** (`AppController.shared`, main thread):
/// `ConfigStore(~/.config/nopeek/config.json)` → `EvidenceLog(~/Library/Logs/NoPeek)`
/// → `Classifier` (built from the config's effective lists) →
/// `Throttler(60 s)` → `Pipeline` → `BannerPolicy` + `BannerPresenter` (T16: the
/// red banner's per-actor cooldown and its non-activating panels) →
/// `LogStreamReader` (default ndjson command
/// + default predicate) → `ProcessWatch` (T13: the remote-tier process table
/// watch, whose watchlist closure reads `config` live) → `MicWatch` (T15: the
/// 2 s microphone poll). Camera detection needs no component of its own: the
/// T14 field-test fix moved it onto the log stream (the parser's
/// `KindRule.cameraDefaults` + the predicate's camera clauses).
///
/// **Live config (T23).** The `Classifier` is no longer a launch-time
/// snapshot: the store's change notification — a Settings save, `Reload
/// config`, or an edit to the file made outside the app — reaches
/// `applyConfig(_:)`, which rebuilds the classifier and swaps it into the
/// running pipeline, rebuilds the auto-kill engine when its quota changed, and
/// rebuilds the banner cooldown when it did. Everything that reads the config
/// through a closure (the remote watchlist, `bannerOnForRemote`,
/// `bannerLevel`, the notification sound) already followed the file live.
/// `start()` arms the file watcher and `stop()` detaches it.
///
/// **Startup order** (`start()`): the `monitor-started` lifecycle line first,
/// then the reader, then the process watch (T13: a 3 s `DispatchSourceTimer`
/// whose polls run on the reader's serial queue, so `tick()` and
/// `pipeline.handle(_:)` serialize with log lines) and the mic watch (T15: the
/// same shape at 2 s), and finally the T18 calibration wizard — which opens by
/// itself on a launch that finds no persisted summary. T21 wraps this with
/// retention purge, the gap check and the heartbeat timer.
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

    /// `~/Library/Application Support/NoPeek/calibration.json` — the spec §9
    /// state directory, holding the last completed wizard run (T18). A
    /// *passing* summary here is what closes the first-launch auto-start gate
    /// (ruling R24).
    static var defaultCalibrationURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NoPeek/calibration.json")
    }

    // MARK: - Components

    /// Spec §7 config; loaded at construction, watched from T23 (`start()`).
    let configStore: ConfigStore
    /// Spec §8 evidence log, one `events-YYYY-MM-DD.ndjson` per day.
    let evidenceLog: EvidenceLog
    /// Notification delivery (spec §6); the app's only permission. Its sound
    /// follows `config.sound` live (T23).
    let notifications: NotificationService

    // MARK: - Calibration (T18, spec §6)

    /// The Calibration Wizard's state machine. Fed every `RawEvent` the app
    /// sees (see `route(_:)`) and driven by the wizard window's 1 s refresh;
    /// ignores everything unless a run is in flight.
    let calibration: CalibrationService

    /// The wizard window. Built here — on the main thread, like everything the
    /// window touches — but its window and views are only created by `show()`.
    ///
    /// Its three dependencies are passed as pieces rather than as `self`: the
    /// language closure reads the live config exactly like `processWatch` and
    /// `bannerPresenter` below, and the record URL is a static.
    @MainActor let calibrationWindow: CalibrationWindowController

    // MARK: - System Checkup (T19, spec §6)

    /// The on-demand checkup (spec §6 `System Checkup…`): read-only probes of
    /// this Mac's open observation channels. The org patterns and the language
    /// are read per run through the closures built below, so a config reload
    /// changes the next checkup without rebuilding the service.
    let checkup: CheckupService

    /// The checkup window, built here — on the main thread, like everything the
    /// window touches — while its window and views are only created by `show()`.
    @MainActor let checkupWindow: CheckupWindowController

    // MARK: - Export (T20, spec §6)

    /// The evidence exporter (plan T20): a date range in, three artifacts out
    /// (md summary + csv table + verbatim ndjson copy) under
    /// `~/Library/Logs/NoPeek/exports` (ruling F4: never `~/Downloads`, so the
    /// app never triggers a folder-permission prompt — the panel's reveal
    /// button is how the user moves the files).
    ///
    /// It only *reads* the log, so the panel may run it while the pipeline
    /// keeps watching; a line appended during an export carries the moment it
    /// was appended, which is after the preset's range end (the press) and so
    /// stays out of the report.
    let exporter: Exporter

    /// The export panel, built on the main thread like the checkup window; its
    /// window and views are only created by `show()`.
    @MainActor let exportPanel: ExportPanelController

    // MARK: - History (T22, spec §6b)

    /// The History window (spec §6b): the evidence log read back as a
    /// filterable, browsable table. Built here — on the main thread, like
    /// everything a window touches — while its window and views are only created
    /// by `show()`; the reads themselves run off the main thread inside it.
    ///
    /// It takes the log's *directory*, not the app's `EvidenceLog` instance:
    /// `EvidenceLog` is deliberately not `Sendable` (T8's single-owner
    /// contract), and this window must read off the main thread, so each read
    /// builds a read-only instance over the same directory — the read path the
    /// T20 exporter already travels.
    @MainActor let historyWindow: HistoryWindowController

    // MARK: - Settings (T23, spec §6c)

    /// The Settings window (spec §6c): the config file as a validated form.
    /// Built here — on the main thread, like everything a window touches —
    /// while its window and views are only created by `show()`.
    ///
    /// Its save path is `ConfigStore.update`, so a save travels exactly the
    /// same route as an external file edit: the store's change notification
    /// rebuilds the live components (see `applyConfig(_:)`). `Purge now` is
    /// routed through `onPurge` to the reader's serial queue, the evidence
    /// log's single owner.
    @MainActor let settingsWindow: SettingsWindowController

    // MARK: - Kill (T21, spec §6d)

    /// The signal engine (stateless): the pid-reuse guard, `SIGTERM` → wait →
    /// `SIGKILL`. Manual kills and the auto-kill hook both go through it.
    private let killController: KillController

    /// The auto-kill loop guard (spec §6d): a rolling per-name quota, so a
    /// process something respawns is not killed forever. Reachable only from the
    /// reader's serial queue — see `autoKillIfRequested(_:)`. Rebuilt by
    /// `applyConfig(_:)` when `autoKillMaxPerHour` changes (the engine takes its
    /// quota once, T21's pinned interface).
    private var autoKillEngine: AutoKillEngine

    /// Serial queue for kill attempts. `KillController` blocks for up to its
    /// three-second wait and the admin path waits for a human, neither of which
    /// may happen on the main thread (the dialog would freeze) nor on the
    /// reader's queue (every log line and poll behind it would stall).
    private let killQueue = DispatchQueue(label: "com.sinsombat.nopeek.kill")

    /// The routing pipeline (T11). Built on first use — it captures `self` —
    /// from `start()` on the main thread, before any callback can touch it,
    /// or by the first `pipeline` use in the config apply.
    private(set) lazy var pipeline: Pipeline = {
        // Read under the lock: a config apply may have already swapped the
        // classifier while this initializer was pending.
        let classifier = classifierLock.withLock { self.classifier }
        return Pipeline(
            classifier: classifier,
            throttler: throttler,
            sink: { [weak self] action in self?.perform(action) },
            // Read live per REMOTE event, so a config reload takes effect
            // without rebuilding the pipeline (spec §7).
            remoteBannerEnabled: { [weak self] in self?.configStore.config.bannerOnForRemote ?? false }
        )
    }()

    /// The `log stream` child (T5) with its default predicate — which already
    /// includes `process == "WindowManager"` for Mission Control.
    private(set) lazy var reader: LogStreamReader = LogStreamReader(
        onLine: { [weak self] line in self?.consume(line) },
        onState: { [weak self] state in self?.readerStateChanged(state) }
    )

    /// The live classifier: what the pipeline routes with and what the
    /// auto-kill hook asks. Guarded by `classifierLock`; written by
    /// `applyConfig(_:)` on the reader's queue and read from any queue.
    private var classifier: Classifier
    /// Guards `classifier`. `Pipeline.setClassifier` has its own lock, so the
    /// two copies are swapped in one order and never observed half-updated.
    private let classifierLock = NSLock()
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

    /// The red banner's per-actor cooldown (T16, spec §5). Rebuilt by
    /// `applyConfig(_:)` when `orgBannerCooldownSeconds` changes — a rebuild
    /// drops the actors' last-shown stamps, which is exactly what "apply this
    /// cooldown now" means.
    private var bannerPolicy: BannerPolicy

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

    /// Guards `tray`, `readerStateValue`, `gapValue` and `started`: the sink
    /// and the reader's state callback write them off the reader queue, the
    /// status menu (T17) reads them on the main thread.
    private let uiLock = NSLock()
    private var tray = TrayModel()
    private var readerStateValue: LogStreamReader.State?
    /// The latest monitoring gap; T24's lifecycle check sets it at startup
    /// (spec §6's gap row). `nil` until then — the menu simply omits the row.
    private var gapValue: GapReport?
    private var started = false

    /// The pending auto-resume of a timed `Pause` (T17, spec §6). Main thread
    /// only: the menu schedules it, and its own work item clears it.
    private var pauseWork: DispatchWorkItem?

    // MARK: - Live configuration (T23)

    /// The config most recently applied to the live components. The reader's
    /// queue owns it: `applyConfig(_:)` runs there, and it is how the double
    /// notification a save produces (once for the update, once for the
    /// watcher observing the write) collapses into one apply.
    private var appliedConfig: NoPeekConfig?

    // MARK: - Init

    @MainActor
    private init() {
        // The store's callback is fixed at construction, but the apply path
        // needs `self` — so it goes through a relay that stays inert until the
        // whole graph exists (see the end of this init).
        let relay = ConfigChangeRelay()

        let configStore = ConfigStore(url: Self.defaultConfigURL, onChange: { relay.forward($0) })
        configStore.load()
        self.configStore = configStore

        // Sound is read live from the config (T23): the Settings toggle
        // silences the next notification without a relaunch.
        self.notifications = NotificationService(sound: { configStore.config.sound })

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

        // The calibration run and its window (T18, spec §6). The service is
        // built eagerly, not lazily like `pipeline`: it is fed from the
        // reader's queue the moment the reader starts, so the first event must
        // never race its creation. The language closure and the record URL are
        // read live, so neither the window nor this wiring holds `self`.
        let calibration = CalibrationService()
        self.calibration = calibration
        self.calibrationWindow = CalibrationWindowController(
            calibration: calibration,
            language: { Language(rawValue: configStore.config.language) ?? Strings.defaultLanguage },
            recordURL: Self.defaultCalibrationURL
        )

        // The System Checkup (T19, spec §6): the same shape — a service plus the
        // window that draws it. The patterns, the process table and the language
        // are read per run, so `Reload config` changes the next checkup; the
        // language closure is shared by the window, which re-renders on refresh.
        let language: @Sendable () -> Language = {
            Language(rawValue: configStore.config.language) ?? Strings.defaultLanguage
        }
        let checkup = CheckupService(
            runner: LiveCommandRunner(),
            orgPatterns: { configStore.config.effectiveOrgPatterns },
            processLister: SystemProcesses.list,
            language: language
        )
        self.checkup = checkup
        self.checkupWindow = CheckupWindowController(checkup: checkup, language: language)

        // The evidence export (T20, spec §6): the exporter reads the log the
        // pipeline writes, and the panel drives it with the three presets. The
        // exporter's default destination — `~/Library/Logs/NoPeek/exports`
        // (ruling F4) — is used as-is; nothing here chooses a folder, so the
        // app has no path to `~/Downloads`.
        let exporter = Exporter(log: evidenceLog)
        self.exporter = exporter
        self.exportPanel = ExportPanelController(exporter: exporter, language: language)

        // The History window (T22, spec §6b): the evidence log read back with
        // filters. It reads the directory rather than the app's `EvidenceLog`
        // (see the property's note) and takes the language closure like the
        // other windows.
        self.historyWindow = HistoryWindowController(
            logDirectory: Self.defaultLogDirectory,
            language: language
        )

        // The Settings window (T23, spec §6c): the config file as a form. The
        // save is a `ConfigStore.update`, so the live apply below is what makes
        // it take effect; the purge is handed to the reader's queue (the log's
        // single owner) with the retention saved in the config.
        let settingsWindow = SettingsWindowController(
            configStore: configStore,
            language: language,
            configURL: Self.defaultConfigURL
        )
        self.settingsWindow = settingsWindow

        // The kill engine and the auto-kill loop guard (T21, spec §6d). The
        // engine is stateless; the guard's quota is the config value at launch
        // and is rebuilt by `applyConfig(_:)` when `autoKillMaxPerHour` changes
        // (the engine takes the quota once, by its pinned interface).
        self.killController = KillController()
        self.autoKillEngine = AutoKillEngine(maxPerHour: configStore.config.autoKillMaxPerHour)

        // The live config is "applied" to start with: `init` built every
        // component from it, so the first notification must not rebuild them
        // for nothing.
        self.appliedConfig = configStore.config

        // Wired last, when every stored property exists: the completion handler
        // is what persists the summary and records the `calibration-result`
        // lifecycle line.
        calibration.onComplete = { [weak self] summary in
            self?.calibrationDidComplete(summary)
        }

        // Also last, for the same reason: the checkup's `checkup-run` line
        // (spec §8) goes through the lazy `reader` to the evidence log, and
        // neither may be reached from a closure captured while an earlier stored
        // property — `checkupWindow` above — was still unassigned. The window
        // fires this for every started run, so `ตรวจใหม่` is recorded too, and
        // the line is appended on the reader's serial queue, the log's single
        // owner, exactly like `config-reloaded`.
        checkupWindow.onRun = { [weak self] in
            guard let self else { return }
            let reader = self.reader
            reader.performSerialized { [weak self] in
                self?.evidenceLog.appendRaw(kind: .checkupRun)
            }
        }

        // Also last, for the same reason: the export's spec §8 lifecycle line
        // (`export-created`) goes through the lazy `reader` to the evidence log
        // — appended on the reader's serial queue, the log's single owner —
        // once the files really exist. A failed export writes no line, so the
        // log never claims an artefact that was not produced.
        exportPanel.onExported = { [weak self] in
            guard let self else { return }
            let reader = self.reader
            reader.performSerialized { [weak self] in
                self?.evidenceLog.appendRaw(kind: .exportCreated)
            }
        }

        // Also last, for the same reason: the notification actions are the app's
        // own (`NotificationService.Action`), and this is the type that owns the
        // kill flow and the reveal (T21, spec §6). The delegate already hops to
        // the main actor.
        notifications.onAction = { [weak self] action in
            Task { await self?.handleNotificationAction(action) }
        }

        // Also last, for the same reason: the History window's three actions are
        // the app's own flows, never re-implemented in the window — `Trust` is
        // the menu's allowlist write, `Kill…` is the T21 confirm-and-kill, and
        // `Export…` opens the T20 panel. The window renders them and shows what
        // they returned.
        historyWindow.onTrust = { [weak self] actor in
            try self?.trust(actor)
        }
        historyWindow.onKill = { [weak self] target in
            guard let self else { return nil }
            return await self.confirmAndKill(target)
        }
        historyWindow.onExport = { [weak self] in
            self?.runExport()
        }

        // Also last, for the same reason: `Purge now` (spec §6c) deletes inside
        // the log directory, which the reader's serial queue owns (T8's single
        // owner) — the same route the other log appends take. The window passes
        // the retention saved in the config, never the half-edited field.
        settingsWindow.onPurge = { [weak self] days in
            guard let self else { return }
            let reader = self.reader
            reader.performSerialized { [weak self] in
                self?.evidenceLog.purgeOldFiles(keepingDays: days)
            }
        }

        // And last of all, the relay: every stored property exists and the
        // whole graph is wired, so a config change can now be applied. The
        // relay holds this weakly, and the store's own closure holds the relay.
        relay.install { [weak self] config in
            self?.configStoreChanged(config)
        }
    }

    // MARK: - Life cycle

    /// Records the boot and starts watching (spec §3: every boot leaves a
    /// `monitor-started` line). Idempotent.
    ///
    /// Main actor: the bootstrap path (`applicationDidFinishLaunching`) is, and
    /// T21's alert-category registration is a `UNUserNotificationCenter` call
    /// like the permission request next to it. Everything scheduled from here —
    /// the reader, the two pollers — runs on its own queue as before.
    @MainActor
    func start() {
        let shouldStart = uiLock.withLock { () -> Bool in
            guard !started else { return false }
            started = true
            return true
        }
        guard shouldStart else { return }

        evidenceLog.appendRaw(kind: .monitorStarted)
        // Spec §6: the alert actions (`Kill` / `เปิดตำแหน่ง`) must exist before
        // the first REMOTE/ORG notification is posted, or a notification that
        // arrives would carry no buttons.
        notifications.registerAlertCategory(language: language)
        // Spec §7: the config file is watched from now on, so an edit made
        // outside the app — a text editor, `cp`, the Settings window's own
        // `ConfigStore.update` — is applied without a relaunch (T23).
        configStore.startWatching()
        reader.start()
        startProcessWatch()
        startMicWatch()

        // Spec §6 + ruling R24: the wizard runs by itself on a launch that has
        // no *passing* calibration — no file, an unreadable one, or a record
        // whose steps did not all pass. A run that only timed out therefore
        // leaves the gate open rather than "calibrating" the machine by
        // existing. The check runs exactly once per launch (here), so an
        // unanswered wizard comes back on the *next* launch — it never re-opens
        // in a loop inside one session.
        if !hasPassedCalibration {
            startCalibration()
        }
    }

    /// Stops the reader and terminates its child, so quitting the app never
    /// leaves an orphaned `log stream` behind, and detaches the config watcher
    /// (T23) so no callback can arrive during teardown. Safe to call when not
    /// started.
    func stop() {
        stopProcessWatch()
        stopMicWatch()
        configStore.stopWatching()
        reader.stop()
        // A run that is cut short by the app quitting is abandoned, not
        // completed: nothing is persisted (see `CalibrationService.cancel`).
        calibration.cancel()
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

    /// The latest monitoring gap, for the menu's gap row (spec §6). T24's
    /// startup check assigns the `GapReport` it detects; until then this is
    /// `nil` and the row does not exist.
    var latestGap: GapReport? {
        get { uiLock.withLock { gapValue } }
        set { uiLock.withLock { gapValue = newValue } }
    }

    /// Whether NORMAL notifications are suppressed right now (spec §6 Pause).
    var isPaused: Bool {
        pipeline.isPaused
    }

    // MARK: - Pause (T17, spec §6)

    /// Pauses NORMAL notifications for `interval` and resumes automatically
    /// (spec §6: `Pause 30 นาที / 1 ชั่วโมง`). ORG and REMOTE are untouched
    /// either way — the pause only gates the pipeline's NORMAL notification
    /// path. Main thread only: the menu calls this, and the auto-resume lands
    /// back on the main queue.
    func pause(for interval: TimeInterval) {
        pauseWork?.cancel()
        pipeline.setPaused(true)
        let work = DispatchWorkItem { [weak self] in self?.resume() }
        pauseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: work)
    }

    /// Lifts a pause immediately (spec §6 `หยุด pause`); also the timed
    /// options' landing. Idempotent. Main thread only.
    func resume() {
        pauseWork?.cancel()
        pauseWork = nil
        pipeline.setPaused(false)
    }

    // MARK: - Config actions (T17, spec §6)

    /// Adds `actor` to the allowlist and persists it through
    /// `ConfigStore.update` (ruling F2). Already-trusted actors are a no-op,
    /// so a write happens only when the list really changes.
    ///
    /// Live since T23: the store's change notification rebuilds the classifier,
    /// so a trusted actor stops classifying at its old tier as soon as the
    /// write lands — not at the next launch.
    func trust(_ actor: String) throws {
        try configStore.update { config in
            guard !config.allowlist.contains(where: {
                $0.caseInsensitiveCompare(actor) == .orderedSame
            }) else { return }
            config.allowlist.append(actor)
        }
    }

    /// Removes one allowlist entry (spec §6 `ยกเลิก trust`), persisted the same
    /// way. An entry that is not present is a no-op. Live like `trust(_:)`.
    func untrust(_ entry: String) throws {
        try configStore.update { config in
            config.allowlist.removeAll { $0 == entry }
        }
    }

    /// Re-reads the config from disk (spec §6 `Reload config`).
    ///
    /// `load()` is a read and does not notify, so the apply is called here
    /// directly — the reload must take effect on whatever the file now holds
    /// (T23's live apply). The reload itself is recorded as the spec §8
    /// lifecycle event `config-reloaded`, appended on the reader's serial
    /// queue, the evidence log's single owner; the apply records a second line
    /// of the same kind only when the file really changed, so a *changed*
    /// reload legitimately leaves two lines ("the user asked to reload" and
    /// "the config changed"), while an unchanged one leaves only this one.
    func reloadConfig() {
        configStore.load()
        configStoreChanged(configStore.config)
        let reader = self.reader
        reader.performSerialized { [weak self] in
            self?.evidenceLog.appendRaw(kind: .configReloaded)
        }
    }

    // MARK: - Live config apply (T23, spec §6c)

    /// The config store's change notification: applied on the reader's serial
    /// queue, so the rebuild is ordered exactly against the events it will
    /// classify (the pipeline's own queue). Called for a Settings save, a menu
    /// reload and a watched file edit alike.
    private func configStoreChanged(_ config: NoPeekConfig) {
        let reader = self.reader
        reader.performSerialized { [weak self] in
            self?.applyConfig(config)
        }
    }

    /// Rebuilds everything that snapshots the config, then hands the new
    /// classifier to the running pipeline.
    ///
    /// Runs on the reader's serial queue (see `configStoreChanged`), which is
    /// the pipeline's single-queue contract and the auto-kill engine's single
    /// owner, so no lock is needed for those two. The classifier copy itself is
    /// lock-protected because `pipeline`'s lazy initializer may read it from
    /// the main thread.
    ///
    /// A no-op when the config is unchanged: a save while watching notifies
    /// twice (the update, then the watcher's own observation of the write), and
    /// only one apply — one rebuild, one `config-reloaded` line — is honest.
    ///
    /// The two stateful pieces are rebuilt only when their input changed: the
    /// `AutoKillEngine`'s quota is a rolling hour of kills-and-halts, and
    /// resetting it on an unrelated save would forget a fight with a respawning
    /// process; the `BannerPolicy`'s cooldown is measured from the actors'
    /// last-shown stamps, and a *changed* cooldown is exactly when those should
    /// be dropped.
    private func applyConfig(_ config: NoPeekConfig) {
        guard config != appliedConfig else { return }
        let previous = appliedConfig
        appliedConfig = config

        let classifier = Classifier(
            org: config.effectiveOrgPatterns,
            noise: config.effectiveSystemNoise,
            allowlist: config.allowlist,
            remote: config.effectiveRemoteControl
        )
        classifierLock.withLock { self.classifier = classifier }
        pipeline.setClassifier(classifier)

        if previous?.autoKillMaxPerHour != config.autoKillMaxPerHour {
            autoKillEngine = AutoKillEngine(maxPerHour: config.autoKillMaxPerHour)
        }
        if previous?.orgBannerCooldownSeconds != config.orgBannerCooldownSeconds {
            bannerPolicy = BannerPolicy(cooldown: TimeInterval(config.orgBannerCooldownSeconds))
        }

        // The alert category's action titles are localized (T21), and the
        // method is re-callable for exactly this: a language change must reach
        // the buttons on the next notification, not the next launch.
        if previous?.language != config.language {
            let language = Language(rawValue: config.language) ?? Strings.defaultLanguage
            let notifications = self.notifications
            Task { @MainActor in
                notifications.registerAlertCategory(language: language)
            }
        }

        evidenceLog.appendRaw(kind: .configReloaded)
    }

    // MARK: - Calibration (T18, spec §6)

    /// Whether this machine has a **passing** calibration on disk — the
    /// first-launch gate's predicate (ruling R24). A missing file, an
    /// unreadable one, and a record whose steps timed out, failed or never ran
    /// all read as "not calibrated", so the wizard stays eligible to open by
    /// itself.
    var hasPassedCalibration: Bool {
        CalibrationService.hasPassedCalibration(at: Self.defaultCalibrationURL)
    }

    /// Starts a calibration run and brings the wizard window up (spec §6
    /// `Calibration Wizard…`; also the first launch's auto-start). Main thread:
    /// the run is drawn by an AppKit window. Safe to call while a run is in
    /// flight — `start()` is a fresh run.
    @MainActor
    func startCalibration() {
        calibration.start()
        calibrationWindow.show()
    }

    /// The run finished — every step has a verdict. Persists the summary and
    /// records the spec §8 `calibration-result` lifecycle line.
    ///
    /// Runs on whichever thread resolved the last step: the reader's queue when
    /// an event did it, the main thread when the wizard window noticed a
    /// timeout. Both the write and the log line are handed to the reader's
    /// serial queue — the `EvidenceLog`'s single owner — and the window picks
    /// the saved line up on its next refresh.
    private func calibrationDidComplete(_ summary: CalibrationSummary) {
        let reader = self.reader
        reader.performSerialized { [weak self] in
            guard let self else { return }
            // Best effort, like the evidence log itself: a failed write leaves
            // the previous record (or none) in place, and the wizard window's
            // `saved` line — which is drawn from the file, not from this call —
            // stays away, so a write failure is visible rather than silent.
            try? self.calibration.persist(summary, to: Self.defaultCalibrationURL)
            self.evidenceLog.appendRaw(kind: .calibrationResult)
        }
    }

    // MARK: - System Checkup (T19, spec §6)

    /// Runs the on-demand checkup and brings its window up (spec §6
    /// `System Checkup…`).
    ///
    /// The window takes the snapshot itself, off the main thread, and fires
    /// `onRun` for every started run — which is where the spec §8 lifecycle
    /// line `checkup-run` is appended (see the window's construction). Main
    /// thread only: the report is drawn by an AppKit window.
    @MainActor
    func runCheckup() {
        checkupWindow.show()
    }

    // MARK: - Export (T20, spec §6)

    /// Opens the export panel (spec §6 `Export รายงาน…`). The panel runs the
    /// export itself, off the main thread, and fires `onExported` when the
    /// three files are written — which is where the spec §8 `export-created`
    /// lifecycle line is appended (see the panel's construction). Main thread
    /// only: the panel is an AppKit window.
    @MainActor
    func runExport() {
        exportPanel.show()
    }

    // MARK: - History (T22, spec §6b)

    /// Opens the History window (spec §6b `History…`): the evidence log as a
    /// filterable table, refreshed while it is open. Main thread only — the
    /// window is AppKit — while its log reads run off the main thread inside it.
    @MainActor
    func runHistory() {
        historyWindow.show()
    }

    // MARK: - Settings (T23, spec §6c)

    /// Opens the Settings window (spec §6c `Settings…`). Main thread only: the
    /// form is AppKit. The save path is the window's own
    /// (`ConfigStore.update`), so nothing here has to be told about it.
    @MainActor
    func runSettings() {
        settingsWindow.show()
    }

    // MARK: - Kill (T21, spec §6d)

    /// The configured UI language (spec §10), read live.
    private var language: Language {
        Language(rawValue: configStore.config.language) ?? Strings.defaultLanguage
    }

    /// The manual kill flow (spec §6d): confirm → signal → on `EPERM` the macOS
    /// admin prompt (**manual only**) → evidence line for every outcome.
    ///
    /// The pid-reuse guard runs **three** times on this path: inside
    /// `KillController` before `SIGTERM`, again before its escalated `SIGKILL`,
    /// and a third time here — after the admin prompt, immediately before the
    /// elevated `kill(1)` that runs as root (that window is human-scale; see
    /// `KillController.guardPasses`).
    ///
    /// Returns the status line to show for what happened, or `nil` when the
    /// user cancelled the confirmation — nothing was attempted in that case, so
    /// nothing is logged.
    ///
    /// Main actor because both dialogs are, and because this is called from the
    /// tray rows, the notification action and (T22) the History window; the
    /// signalling itself runs on `killQueue`, so the UI never blocks.
    @MainActor
    func confirmAndKill(_ target: KillTarget) async -> String? {
        // Never NoPeek's own pid (T21 global constraint): menu-bar apps are
        // matched by name like anything else, and killing itself would end the
        // monitoring session it is reporting about.
        guard target.pid != getpid() else {
            return Strings.t("kill.done.self", language)
        }
        guard let pid = target.pid, pid > 0 else { return nil }
        // The spec §6d confirmation is mandatory for every manual kill.
        guard let force = KillConfirmDialog.present(target: target, language: language) else {
            return nil
        }

        let outcome = await runKill(pid: pid, name: target.actor, force: force)
        let signal = force ? SIGKILL : SIGTERM
        logKill(target, summary: KillCopy.logSummary(outcome, name: target.actor, pid: pid, initiator: .manual))

        guard outcome == .noPermission else {
            return KillCopy.outcomeLine(outcome, name: target.actor, language: language)
        }

        // EPERM → the system's admin prompt, this time only (spec §6d).
        guard KillConfirmDialog.presentAdminPrompt(language: language) else {
            logKill(
                target,
                summary: KillCopy.adminLogSummary(success: false, name: target.actor, pid: pid, signal: signal)
            )
            return KillCopy.adminCancelledLine(language: language)
        }

        // The elevated `kill(1)` runs as **root**, and the password dialog is a
        // human-scale window — long enough for this pid to die and be recycled,
        // which the first guard (before `SIGTERM`) cannot see. So the guard runs
        // again here, immediately before the elevated command, and a failure
        // signals nothing: spec §6d's pid-reuse rule has to hold on the one
        // path that is stronger than the app itself.
        guard KillController.guardPasses(pid: pid, expectedName: target.actor) else {
            logKill(target, summary: KillCopy.adminRefusalLogSummary(name: target.actor, pid: pid))
            return KillCopy.outcomeLine(.refusedNameMismatch, name: target.actor, language: language)
        }

        let elevated = await runAdminKill(pid: pid, signal: signal)
        logKill(
            target,
            summary: KillCopy.adminLogSummary(success: elevated, name: target.actor, pid: pid, signal: signal)
        )
        return KillCopy.adminResultLine(success: elevated, name: target.actor, language: language)
    }

    /// One attempt on the kill queue, handed back to the caller's actor.
    private func runKill(pid: Int32, name: String, force: Bool) async -> KillOutcome {
        let controller = killController
        return await withCheckedContinuation { continuation in
            killQueue.async {
                continuation.resume(returning: controller.kill(pid: pid, expectedName: name, force: force))
            }
        }
    }

    /// The elevated retry: `osascript … with administrator privileges` on the
    /// kill queue, because it blocks on the system dialog and the `kill(1)` it
    /// starts. `true` only when that command exited 0.
    private func runAdminKill(pid: Int32, signal: Int32) async -> Bool {
        await withCheckedContinuation { continuation in
            killQueue.async {
                continuation.resume(returning: AdminKiller.killWithPrivileges(pid: pid, signal: signal))
            }
        }
    }

    /// Appends the spec §8 `process-kill` line — on the reader's serial queue,
    /// the evidence log's single owner (T8's contract).
    private func logKill(_ target: KillTarget, summary: String) {
        let reader = self.reader
        reader.performSerialized { [weak self] in
            self?.evidenceLog.appendRaw(kind: .processKill, actor: target.actor, rawSummary: summary)
        }
    }

    // MARK: - Notification actions (T21, spec §6)

    /// Runs one notification action. Main actor: both paths are interaction —
    /// the confirm dialog, or a Finder reveal.
    @MainActor
    private func handleNotificationAction(_ action: NotificationService.Action) async {
        switch action {
        case .kill(let target):
            // The same confirmed flow as a tray row: a notification button is a
            // shortcut to the dialog, never a way around it (spec §6d).
            _ = await confirmAndKill(target)
        case .showLocation(let target):
            ProcessLocation.openInFinder(for: target)
        }
    }

    // MARK: - Event funnel

    /// Routes one observed event to every consumer: the pipeline (classify →
    /// log → notify / banner / tray) and the T18 calibration run. Both sit on
    /// the reader's serial queue.
    ///
    /// The calibration service is offered *every* event — it is the one that
    /// knows whether a run is in flight and whether the event is the current
    /// step's proof, so there is no separate gate here to race against (or to
    /// forget). When no run is in flight the call is a lock acquisition and a
    /// comparison.
    private func route(_ raw: RawEvent) {
        pipeline.handle(raw)
        calibration.ingest(raw)
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
    /// and the thread id groups per tier (R10). The three identity fields travel
    /// in `userInfo`, which is what the T21 actions (`Kill` / `เปิดตำแหน่ง`)
    /// read back.
    private func postNotification(for event: ClassifiedEvent) {
        let language = Language(rawValue: configStore.config.language) ?? Strings.defaultLanguage
        guard let copy = Strings.notificationCopy(for: event, language: language) else { return }

        let tier = event.tier
        let notifications = self.notifications
        let userInfo = NotificationService.eventUserInfo(
            actor: event.event.actor,
            actorPath: event.event.actorPath,
            pid: event.event.pid
        )

        Task { @MainActor in
            notifications.post(
                title: copy.title,
                body: copy.body,
                threadID: NotificationService.threadID(for: tier),
                categoryID: NotificationService.carriesAlertActions(tier)
                    ? NotificationService.alertCategoryID
                    : nil,
                userInfo: userInfo
            )
        }
    }

    /// Posts one already-composed notification (T21's auto-kill notices, which
    /// are the app's own actions rather than an observation and so have no
    /// `Tier`): grouped under the system thread like the other monitor-health
    /// notifications (F3).
    private func postNotification(_ copy: NotificationCopy) {
        let notifications = self.notifications
        Task { @MainActor in
            notifications.post(
                title: copy.title,
                body: copy.body,
                threadID: NotificationService.systemThreadID
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
        route(raw)
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
                // name that just appeared. Each event gets the T21 auto-kill
                // hook first — the response — and is then routed exactly like
                // a log-stream one (classify → log → notify / banner / tray,
                // and offered to a calibration run): the observation is the
                // evidence log's business even when the process just died.
                for raw in self.processWatch.tick() {
                    self.autoKillIfRequested(raw)
                    self.route(raw)
                }
            }
        }
        processWatchTimer = timer
        timer.resume()
    }

    // MARK: - Auto-kill (T21, spec §6d)

    /// The auto-kill hook: runs **before** the event reaches the pipeline, on
    /// the reader's serial queue (the engine's single owner, T13's contract).
    ///
    /// Every gate is deliberate:
    /// - `autoKillEnabled` — off unless the user turned it on (spec §7 default
    ///   `false`);
    /// - the actor must be in `autoKillNames`, matched case-insensitively and
    ///   **exactly** (never as a substring — this decides who dies);
    /// - the event must classify **REMOTE** (plan T21): an org-patterned actor
    ///   stays manual-only, where the confirm dialog asks the user, and a name
    ///   that is not on the remote watchlist produces no event to begin with
    ///   (spec §6d "ต้องใส่ชื่อเองทีละตัว"; `remoteControlExtra` is how a test
    ///   process joins the watchlist — ruling F5);
    /// - never NoPeek's own pid;
    /// - the loop guard's quota: one `process-kill` line and one notification
    ///   when a name's hour fills up, then silence until the window slides.
    ///
    /// `EPERM` is a plain outcome here: auto-kill **never** raises the admin
    /// prompt (spec §6d), so the line says so and the user gets one notice.
    /// The event is forwarded to the pipeline either way.
    private func autoKillIfRequested(_ raw: RawEvent) {
        let config = configStore.config
        guard config.autoKillEnabled, raw.kind == .remoteControlProcess else { return }
        guard let pid = raw.pid, pid > 0, pid != getpid() else { return }
        guard config.autoKillNames.contains(where: {
            $0.caseInsensitiveCompare(raw.actor) == .orderedSame
        }) else { return }
        guard classifierLock.withLock({ classifier }).classify(raw).tier == .remote else { return }

        switch autoKillEngine.evaluate(actor: raw.actor) {
        case .skip:
            return

        case .halted:
            // One line and one notification per halted episode — the guard
            // exists to stop a fight with whatever keeps respawning the
            // process, and that fight would otherwise be loud, not quiet.
            guard autoKillEngine.takeHaltNotice(actor: raw.actor) else { return }
            let count = autoKillEngine.killCount(actor: raw.actor)
            evidenceLog.appendRaw(
                kind: .processKill,
                actor: raw.actor,
                rawSummary: KillCopy.haltLogSummary(name: raw.actor, count: count)
            )
            postNotification(KillCopy.haltNotification(name: raw.actor, count: count, language: language))

        case .kill:
            // TERM → wait → KILL, on this queue: the two other options are the
            // main thread (a frozen menu) and a second queue (evidence lines
            // ordered around a log the pipeline owns). The wait is bounded at
            // 3 s and only happens for a process that ignores SIGTERM.
            let outcome = killController.kill(pid: pid, expectedName: raw.actor, force: false)
            evidenceLog.appendRaw(
                kind: .processKill,
                actor: raw.actor,
                rawSummary: KillCopy.logSummary(outcome, name: raw.actor, pid: pid, initiator: .auto)
            )
            if let copy = KillCopy.autoKillNotification(
                outcome,
                name: raw.actor,
                pid: pid,
                language: language
            ) {
                postNotification(copy)
            }
        }
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
                // the tier the user can mute. (It is also the calibration
                // wizard's mic proof, which is why it goes through `route`.)
                guard let raw = self.micWatch.tick() else { return }
                self.route(raw)
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

// MARK: - ConfigChangeRelay

/// Stands between `ConfigStore` and `AppController` for the one moment neither
/// can reach the other: the store's `onChange` is fixed at construction, while
/// the apply path needs the fully built controller.
///
/// The store's closure captures the relay; the controller installs its handler
/// at the end of its own `init`. Until then the relay is inert, and a config
/// change that somehow arrived before that would be dropped rather than touch
/// a half-built object — which is exactly the ordering the app has: the store
/// does not notify during `load()`.
///
/// Threading: `ConfigStore` may call back from its watch queue, so both ends
/// are lock-protected.
private final class ConfigChangeRelay: @unchecked Sendable {

    private let lock = NSLock()
    private var handler: ((NoPeekConfig) -> Void)?

    /// Installs the handler (last call wins; the app calls it once).
    func install(_ handler: @escaping (NoPeekConfig) -> Void) {
        lock.withLock { self.handler = handler }
    }

    /// Forwards one change, if anyone is listening yet.
    func forward(_ config: NoPeekConfig) {
        let handler = lock.withLock { self.handler }
        handler?(config)
    }
}
