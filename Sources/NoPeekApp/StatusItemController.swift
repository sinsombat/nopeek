import AppKit

import PWCore

// MARK: - StatusItemController

/// Owns the menu-bar item (T17, spec §6): the four-state icon, the dropdown
/// menu's life cycle, and the menu actions themselves.
///
/// **Icon freshness.** A 2 s repeating timer on the main run loop (`.common`
/// mode, so it keeps ticking while the menu is open) re-evaluates the icon.
/// That is what lets the "active" window lapse on its own and what surfaces a
/// reader degradation well inside acceptance 7's 10 s budget. Menu actions
/// refresh the icon immediately; nothing in `AppController` has to push into
/// the UI.
///
/// **Menu freshness.** `NSMenuDelegate.menuNeedsUpdate` rebuilds the whole
/// menu through `MenuBuilder` every time it opens, so the status line, the ten
/// recent events and the trust lists are sampled at open time.
///
/// **Confirmation.** Trust / untrust / reload write the config and confirm
/// with a status-line message for a few seconds — deliberately without a
/// notification (spec §6's menu actions are config edits, not observations).
///
/// Everything here runs on the main actor — AppKit and the menu actions are
/// main-thread by construction — and `AppController`'s menu-facing accessors
/// are lock-protected for exactly this reader.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {

    /// Icon refresh cadence. Two seconds bounds both the "active" window
    /// expiring and a reader degradation appearing; the cost is one state
    /// sample per tick.
    private static let iconRefreshInterval: TimeInterval = 2

    /// How long a confirmation message replaces the status line.
    private static let confirmationSeconds: TimeInterval = 6

    private let controller: AppController
    private let menuBuilder: MenuBuilder

    private var statusItem: NSStatusItem?
    private var refreshTimer: Timer?
    /// One resolved `NSImage` per state (the symbol never changes). Cleared
    /// when the config language changes: the image carries the localized
    /// accessibility description, so a live language switch must not keep the
    /// old one (T23's live apply).
    private var iconCache: [MenuIconState: NSImage] = [:]
    private var iconCacheLanguage: Language?
    /// The warning row of the menu as currently built; refreshed when the
    /// async permission check lands.
    private var notificationWarningItem: NSMenuItem?
    /// Status-line override and its deadline (see `showConfirmation`).
    private var confirmation: (message: String, deadline: Date)?

    init(controller: AppController = .shared) {
        self.controller = controller
        self.menuBuilder = MenuBuilder(controller: controller)
        super.init()
    }

    // MARK: - Set-up

    /// Puts the item in the menu bar and starts the refresh timer. Called once
    /// from `applicationDidFinishLaunching`, before `controller.start()`.
    func setUp() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item

        rebuildMenu()
        updateIcon()

        let timer = Timer(timeInterval: Self.iconRefreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateIcon() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    // MARK: - Menu life cycle

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
        // Spec §6 warning row: re-check the permission on every open (no
        // prompt), so revoking access in System Settings shows up without a
        // relaunch.
        Task {
            await refreshNotificationWarning()
        }
    }

    /// Pulls the notification permission again and adjusts the warning row.
    /// Called from the menu-open path and once after the launch prompt was
    /// answered.
    func refreshNotificationWarning() async {
        await controller.notifications.refreshStatus()
        notificationWarningItem?.isHidden = !controller.notifications.isDenied
    }

    private func rebuildMenu() {
        guard let menu = statusItem?.menu else { return }
        // One sample of the tray feeds both the state and the per-row actions,
        // so `state.eventRows[i]` and `events[i]` are always the same event.
        let events = controller.recentEvents
        notificationWarningItem = menuBuilder.populate(
            menu,
            with: currentState(events: events, now: Date()),
            events: events,
            language: language,
            target: self
        )
    }

    // MARK: - State sampling

    private var language: Language {
        Language(rawValue: controller.configStore.config.language) ?? Strings.defaultLanguage
    }

    private func currentState(events: [ClassifiedEvent], now: Date) -> MenuState {
        var state = MenuStateBuilder(language: language).state(
            recentEvents: events,
            readerState: controller.logStreamState,
            paused: controller.isPaused,
            gap: controller.latestGap,
            allowlist: controller.configStore.config.allowlist,
            now: now
        )
        if let confirmation, confirmation.deadline > now {
            state.statusLine = confirmation.message
        }
        return state
    }

    // MARK: - Icon

    private func updateIcon() {
        guard let button = statusItem?.button else { return }

        // Only the icon is sampled here — the menu's rows are built on open,
        // and this timer ticks every 2 s.
        let icon = MenuStateBuilder(language: language).iconState(
            recentEvents: controller.recentEvents,
            readerState: controller.logStreamState,
            paused: controller.isPaused,
            now: Date()
        )
        let tooltip = Strings.t(icon.tooltipKey, language)
        let image = iconImage(for: icon, tooltip: tooltip)

        button.image = image
        button.toolTip = tooltip
        // Spec §6: the state colours on top of the per-state glyphs — red for
        // a live observation, yellow while the reader is down. `nil` leaves
        // normal and paused in the menu bar's own tint. `contentTintColor`
        // applies because the images are templates.
        button.contentTintColor = switch icon {
        case .active: .systemRed
        case .degraded: .systemYellow
        case .normal, .paused: nil
        }
        // Defensive fallback, as in the M0 skeleton: an empty status item
        // would be invisible, so a missing symbol degrades to the name.
        button.title = image == nil ? Strings.t("app.name", language) : ""
    }

    /// Resolved once per state and cached. `isTemplate` keeps the icon
    /// following light/dark menu-bar styling (spec §6), and the tooltip
    /// doubles as the image's accessibility description.
    private func iconImage(for icon: MenuIconState, tooltip: String) -> NSImage? {
        let language = self.language
        if iconCacheLanguage != language {
            iconCache.removeAll()
            iconCacheLanguage = language
        }
        if let cached = iconCache[icon] { return cached }
        let image = NSImage(systemSymbolName: icon.symbolName, accessibilityDescription: tooltip)
            ?? NSImage(systemSymbolName: MenuIconState.normal.symbolName, accessibilityDescription: tooltip)
        image?.isTemplate = true
        if let image {
            iconCache[icon] = image
        }
        return image
    }

    // MARK: - Confirmation

    private func showConfirmation(_ message: String) {
        confirmation = (message, Date().addingTimeInterval(Self.confirmationSeconds))
    }

    // MARK: - Menu actions

    @objc func trustActor(_ sender: NSMenuItem) {
        guard let actor = sender.representedObject as? String else { return }
        do {
            try controller.trust(actor)
            showConfirmation(String(format: Strings.t("menu.trust.done", language), actor))
        } catch {
            presentConfigError()
        }
    }

    @objc func untrustEntry(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? String else { return }
        do {
            try controller.untrust(entry)
            showConfirmation(String(format: Strings.t("menu.untrust.done", language), entry))
        } catch {
            presentConfigError()
        }
    }

    /// Spec §6d `Kill` on a REMOTE/ORG event row: the confirm dialog and, on
    /// EPERM, the macOS admin prompt — the whole manual flow lives in
    /// `AppController.confirmAndKill`. A cancelled dialog returns `nil` and
    /// changes nothing here.
    @objc func killRow(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? KillTarget else { return }
        Task { @MainActor in
            if let message = await controller.confirmAndKill(target) {
                showConfirmation(message)
            }
            // The killed process may have been holding the "active" icon.
            updateIcon()
        }
    }

    /// Spec §6d `เปิดตำแหน่ง`: reveal the process's bundle (or executable) in
    /// Finder. A row without a path or pid never offers this, so a miss here is
    /// an honest no-op.
    @objc func revealRow(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? KillTarget else { return }
        ProcessLocation.openInFinder(for: target)
    }

    /// Spec §6 `Test alert`: one fake notification per user-facing tier, so
    /// banner and sound can be verified without a real capture.
    ///
    /// Posted through the core `post`, deliberately **without** the
    /// `nopeek-alert` category: a test notification names no process, so the
    /// tier convenience would attach `Kill` / `ShowLocation` buttons that
    /// resolve to a `nil` target and do nothing when pressed. The tier table's
    /// sound rule is kept (ORG/REMOTE always sound).
    @objc func testAlert(_ sender: Any?) {
        for tier in [Tier.org, .remote, .normal] {
            let name = tier.rawValue.lowercased()
            controller.notifications.post(
                title: Strings.t("notif.\(name).title", language),
                body: String(format: Strings.t("notif.test.body", language), tier.rawValue),
                threadID: NotificationService.threadID(for: tier),
                sound: NotificationService.carriesAlertActions(tier) ? true : nil
            )
        }
    }

    /// Spec §6 `Calibration Wizard…`: start a run and put the wizard window up
    /// (the first launch does the same by itself when no summary exists).
    @objc func runCalibration(_ sender: Any?) {
        controller.startCalibration()
    }

    /// Spec §6 `System Checkup…`: a fresh snapshot in the checkup window.
    @objc func runCheckup(_ sender: Any?) {
        controller.runCheckup()
    }

    /// Spec §6 `Export รายงาน…`: the export panel — 7 วัน / 30 วัน / ทั้งหมด
    /// over the evidence log (T20).
    @objc func runExport(_ sender: Any?) {
        controller.runExport()
    }

    /// Spec §6b `History…`: the evidence log read back with filters, refreshed
    /// while the window is open (T22).
    @objc func runHistory(_ sender: Any?) {
        controller.runHistory()
    }

    /// Spec §6c `Settings…`: the config file as a validated form (T23). Its
    /// save applies live — the store's change notification is what rebuilds
    /// the classifier, so nothing has to be refreshed here.
    @objc func runSettings(_ sender: Any?) {
        controller.runSettings()
    }

    @objc func pauseThirtyMinutes(_ sender: Any?) {
        controller.pause(for: 30 * 60)
        updateIcon()
    }

    @objc func pauseOneHour(_ sender: Any?) {
        controller.pause(for: 60 * 60)
        updateIcon()
    }

    @objc func resumeMonitoring(_ sender: Any?) {
        controller.resume()
        updateIcon()
    }

    @objc func openLogFolder(_ sender: Any?) {
        let url = AppController.defaultLogDirectory
        // Created first so the click always lands somewhere, even on a fresh
        // install with no events yet (the banner's click does the same).
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    @objc func openConfigFile(_ sender: Any?) {
        let url = AppController.defaultConfigURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    @objc func reloadConfigFromMenu(_ sender: Any?) {
        controller.reloadConfig()
        showConfirmation(Strings.t("menu.reload.done", language))
    }

    /// Spec §6 `About`: name, version and the spec §13 limits one-liner, in a
    /// standard panel.
    @objc func showAbout(_ sender: Any?) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = Strings.t("app.name", language)
        alert.informativeText = String(format: Strings.t("about.version", language), Self.version)
            + "\n" + Strings.t("about.limits", language)
        alert.addButton(withTitle: Strings.t("about.ok", language))
        NSApp.activate()
        alert.runModal()
    }

    private func presentConfigError() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = Strings.t("menu.config.failed", language)
        alert.addButton(withTitle: Strings.t("about.ok", language))
        NSApp.activate()
        alert.runModal()
    }

    /// The bundle's version (`CFBundleShortVersionString`; 1.0 in the packaged
    /// app). The literal keeps an unbundled `swift run` honest.
    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
}
