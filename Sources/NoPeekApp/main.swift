import AppKit

// NoPeek — menu-bar app bootstrap (M0 skeleton, wired in T12; full status
// menu in T17).
//
// This file is the process entry point only: it keeps the process out of App
// Nap, hands the menu bar to `StatusItemController`, asks for notification
// permission and starts the detection chain in `AppController`.
//
// Spec references: §3 (architecture), §6 (alert UX, notification permission),
// §9 (LSUIElement, no Dock icon), §10 (TH default, all copy through `Strings`),
// §12 (App Nap mitigation).

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Token of the `.userInitiated` activity, retained for the process lifetime.
    private var activity: NSObjectProtocol?

    /// The detection chain: config → evidence log → classifier → throttler →
    /// pipeline → log stream (T12). Same instance the whole app uses, so there
    /// is exactly one `UNUserNotificationCenter` delegate.
    private let controller = AppController.shared

    /// The status item and its menu (T17): four-state icon, status and recent
    /// rows, and the trust / pause / reload actions.
    private let statusItemController = StatusItemController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Spec §12: App Nap would delay the pollers past the 5 s detect budget.
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiated,
            reason: "NoPeek observes screen capture / remote control / camera / mic activity"
        )

        statusItemController.setUp()

        // Spec §6: request notification permission on first launch. The system
        // prompts only while the status is `notDetermined`, so re-launches after
        // a decision never nag. The menu's warning row follows the answer.
        Task {
            await controller.notifications.requestPermission()
            await statusItemController.refreshNotificationWarning()
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
}

let application = NSApplication.shared
// Accessory = no Dock icon, no app switcher entry; `LSUIElement` in Info.plist
// does the same thing for the packaged bundle (spec §9).
application.setActivationPolicy(.accessory)

let appDelegate = AppDelegate()
application.delegate = appDelegate

application.run()
