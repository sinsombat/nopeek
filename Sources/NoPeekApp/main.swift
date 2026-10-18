import AppKit

import PWCore

// NoPeek — menu-bar app bootstrap (M0 skeleton, wired in T12).
//
// This file is the process entry point only. It keeps the process out of App
// Nap, puts the shield in the menu bar and offers `Test alert` + Quit; the
// detection chain itself lives in `AppController` (T12), which later tasks
// (T13–T21) grow.
//
// Spec references: §3 (architecture), §6 (alert UX, notification permission),
// §9 (LSUIElement, no Dock icon), §10 (TH default, all copy through `Strings`),
// §12 (App Nap mitigation).

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// Token of the `.userInitiated` activity, retained for the process lifetime.
    private var activity: NSObjectProtocol?
    private var statusItem: NSStatusItem?

    /// The detection chain: config → evidence log → classifier → throttler →
    /// pipeline → log stream (T12). Same instance the whole app uses, so there
    /// is exactly one `UNUserNotificationCenter` delegate.
    private let controller = AppController.shared

    /// Notification delivery (spec §6). Notification permission is the only
    /// permission this app ever requests.
    private var notifications: NotificationService { controller.notifications }

    /// Spec §6 warning row: shown only while notification access is denied.
    private var notificationWarningItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Spec §12: App Nap would delay the pollers past the 5 s detect budget.
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiated,
            reason: "NoPeek observes screen capture / remote control / camera / mic activity"
        )

        setUpStatusItem()

        // Spec §6: request notification permission on first launch. The system
        // prompts only while the status is `notDetermined`, so re-launches after
        // a decision never nag.
        Task {
            await notifications.requestPermission()
            updateNotificationWarning()
        }

        // Spec §3: record the boot (`monitor-started`) and start watching.
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Terminates the `log stream` child so no orphan outlives the app.
        controller.stop()
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
    }

    /// Status bar item with an SF Symbol shield and the M0 menu.
    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = item.button {
            let icon = NSImage(
                systemSymbolName: "shield",
                accessibilityDescription: Strings.t("app.name")
            )
            icon?.isTemplate = true
            button.image = icon
            // Defensive fallback: an empty status item would be invisible.
            if icon == nil {
                button.title = Strings.t("app.name")
            }
        }

        let menu = NSMenu()
        menu.delegate = self

        // Spec §6: permission warning (hidden until we know access is denied).
        // The red banner path does not depend on notification permission.
        let warning = NSMenuItem(
            title: Strings.t("menu.notif.denied"),
            action: nil,
            keyEquivalent: ""
        )
        warning.isEnabled = false
        warning.isHidden = true
        menu.addItem(warning)
        notificationWarningItem = warning

        // Spec §6 `Test alert`: one fake event per user-facing tier so banner
        // and sound can be verified without waiting for a real capture.
        let testItem = NSMenuItem(
            title: Strings.t("menu.test"),
            action: #selector(testAlert(_:)),
            keyEquivalent: ""
        )
        testItem.target = self
        menu.addItem(testItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: Strings.t("menu.quit"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
    }

    // MARK: - Menu state

    /// Re-check the permission whenever the menu opens, so revoking notification
    /// access in System Settings surfaces the warning without a relaunch.
    func menuNeedsUpdate(_ menu: NSMenu) {
        updateNotificationWarning()
        Task {
            await notifications.refreshStatus()
            updateNotificationWarning()
        }
    }

    private func updateNotificationWarning() {
        notificationWarningItem?.isHidden = !notifications.isDenied
    }

    // MARK: - Actions

    /// Spec §6 `Test alert`: posts one fake notification per user-facing tier.
    /// `post(title:body:tier:)` sets `threadIdentifier = "nopeek-<tier>"`, so the
    /// three alerts arrive pre-grouped; the tier names in the body make them
    /// distinguishable in Notification Center.
    @objc private func testAlert(_ sender: Any?) {
        for tier in [Tier.org, .remote, .normal] {
            let name = tier.rawValue.lowercased()
            notifications.post(
                title: Strings.t("notif.\(name).title"),
                body: String(format: Strings.t("notif.test.body"), tier.rawValue),
                tier: tier
            )
        }
    }
}

let application = NSApplication.shared
// Accessory = no Dock icon, no app switcher entry; `LSUIElement` in Info.plist
// does the same thing for the packaged bundle (spec §9).
application.setActivationPolicy(.accessory)

let appDelegate = AppDelegate()
application.delegate = appDelegate

application.run()
