import AppKit

// NoPeek — menu-bar app bootstrap (M0 skeleton).
//
// This file is the process entry point only. It keeps the process out of App
// Nap, puts the shield in the menu bar and offers Quit. Later tasks grow on it:
// T3 adds the `Test alert` item, T12 wires the watchers via `AppController`,
// T17 replaces the throwaway menu with the real one.
//
// Spec references: §9 (LSUIElement, no Dock icon), §12 (App Nap mitigation).

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Token of the `.userInitiated` activity, retained for the process lifetime.
    private var activity: NSObjectProtocol?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Spec §12: App Nap would delay the pollers past the 5 s detect budget.
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiated,
            reason: "NoPeek observes screen capture / remote control / camera / mic activity"
        )

        setUpStatusItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
    }

    /// Status bar item with an SF Symbol shield and a Quit-only menu.
    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = item.button {
            let icon = NSImage(systemSymbolName: "shield", accessibilityDescription: "NoPeek")
            icon?.isTemplate = true
            button.image = icon
            // Defensive fallback: an empty status item would be invisible.
            if icon == nil {
                button.title = "NoPeek"
            }
        }

        let menu = NSMenu()
        let quitItem = NSMenuItem(
            title: "Quit NoPeek",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)
        item.menu = menu

        statusItem = item
    }
}

let application = NSApplication.shared
// Accessory = no Dock icon, no app switcher entry; `LSUIElement` in Info.plist
// does the same thing for the packaged bundle (spec §9).
application.setActivationPolicy(.accessory)

let appDelegate = AppDelegate()
application.delegate = appDelegate

application.run()
