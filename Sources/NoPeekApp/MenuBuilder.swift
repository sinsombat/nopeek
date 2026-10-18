import AppKit

import PWCore

// MARK: - MenuBuilder

/// Turns a `MenuState` into the status menu's AppKit items (T17, spec §6).
///
/// The division of labour: `MenuStateBuilder` (PWCore) decides *what* the menu
/// says — icon state, status line, rows, trust lists — and this type decides
/// how it is laid out: titles from `Strings`, submenus, separators, and the
/// notification-permission warning row. Every actionable row is wired to a
/// `StatusItemController` selector; `Quit` is the exception, travelling the
/// responder chain to `NSApplication.terminate` with a nil target.
///
/// `autoenablesItems` is switched off and each row's `isEnabled` is set
/// explicitly. The menu is rebuilt from fresh state on every open
/// (`menuNeedsUpdate`), so AppKit's automatic validation would only fight the
/// rebuild — e.g. the `หยุด pause` row must be greyed exactly while the
/// pipeline is not paused.
@MainActor
final class MenuBuilder {

    private let controller: AppController

    init(controller: AppController) {
        self.controller = controller
    }

    /// Rebuilds `menu` from `state` and returns the notification-permission
    /// warning row, so the caller can refresh its visibility once the async
    /// permission check lands.
    @discardableResult
    func populate(
        _ menu: NSMenu,
        with state: MenuState,
        language: Language,
        target: StatusItemController
    ) -> NSMenuItem {
        menu.removeAllItems()
        menu.autoenablesItems = false

        // Spec §6: the permission warning sits on top (hidden unless access
        // was denied); the banner path does not depend on the permission.
        let warning = infoRow(Strings.t("menu.notif.denied", language))
        warning.isHidden = !controller.notifications.isDenied
        menu.addItem(warning)

        // Status header (spec §6): the idle / "กำลังถูกแคปจอโดย …" line and,
        // once T24 has set one, the latest gap below it.
        menu.addItem(infoRow(state.statusLine))
        if let gapLine = state.gapLine {
            menu.addItem(infoRow(gapLine))
        }

        menu.addItem(.separator())

        // Spec §6: the ten latest events, newest first (the empty state is a
        // row of its own when the tray has nothing).
        for row in state.eventRows {
            menu.addItem(infoRow(row))
        }

        menu.addItem(.separator())

        menu.addItem(trustItem(state: state, language: language, target: target))
        menu.addItem(untrustItem(state: state, language: language, target: target))

        menu.addItem(
            actionRow(
                Strings.t("menu.test", language),
                #selector(StatusItemController.testAlert(_:)),
                target
            )
        )

        menu.addItem(.separator())

        // Spec §6: `Pause 30 นาที / 1 ชั่วโมง / หยุด pause`. The timed rows
        // stay available so a pause can be re-armed; the resume row is
        // actionable exactly while paused.
        menu.addItem(
            actionRow(
                Strings.t("menu.pause.30m", language),
                #selector(StatusItemController.pauseThirtyMinutes(_:)),
                target
            )
        )
        menu.addItem(
            actionRow(
                Strings.t("menu.pause.1h", language),
                #selector(StatusItemController.pauseOneHour(_:)),
                target
            )
        )
        let resume = actionRow(
            Strings.t("menu.pause.resume", language),
            #selector(StatusItemController.resumeMonitoring(_:)),
            target
        )
        resume.isEnabled = state.isPaused
        menu.addItem(resume)

        menu.addItem(.separator())

        menu.addItem(
            actionRow(
                Strings.t("menu.openLog", language),
                #selector(StatusItemController.openLogFolder(_:)),
                target
            )
        )
        menu.addItem(
            actionRow(
                Strings.t("menu.openConfig", language),
                #selector(StatusItemController.openConfigFile(_:)),
                target
            )
        )
        menu.addItem(
            actionRow(
                Strings.t("menu.reloadConfig", language),
                #selector(StatusItemController.reloadConfigFromMenu(_:)),
                target
            )
        )

        menu.addItem(.separator())

        menu.addItem(
            actionRow(
                Strings.t("menu.about", language),
                #selector(StatusItemController.showAbout(_:)),
                target
            )
        )

        menu.addItem(.separator())

        // Nil target: the action travels the responder chain to `NSApp`.
        menu.addItem(
            actionRow(Strings.t("menu.quit", language), #selector(NSApplication.terminate(_:)), nil, key: "q")
        )

        return warning
    }

    // MARK: - Trust rows

    /// `Trust แอปนี้…`: one entry per distinct actor of the recent events, in
    /// tray order (newest first). Actors that are already allowlisted carry
    /// the checkmark; the row is disabled while there is nothing to trust.
    private func trustItem(
        state: MenuState,
        language: Language,
        target: StatusItemController
    ) -> NSMenuItem {
        let item = NSMenuItem(title: Strings.t("menu.trust", language), action: nil, keyEquivalent: "")
        item.isEnabled = !state.trustActors.isEmpty

        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for actor in state.trustActors {
            let entry = NSMenuItem(
                title: actor,
                action: #selector(StatusItemController.trustActor(_:)),
                keyEquivalent: ""
            )
            entry.target = target
            entry.representedObject = actor
            if state.allowlist.contains(where: { $0.caseInsensitiveCompare(actor) == .orderedSame }) {
                entry.state = .on
            }
            submenu.addItem(entry)
        }
        item.submenu = submenu.numberOfItems > 0 ? submenu : nil
        return item
    }

    /// `ยกเลิก trust`: the current allowlist verbatim, in config-file order.
    /// Disabled (and arrow-less) while the list is empty.
    private func untrustItem(
        state: MenuState,
        language: Language,
        target: StatusItemController
    ) -> NSMenuItem {
        let item = NSMenuItem(title: Strings.t("menu.untrust", language), action: nil, keyEquivalent: "")
        item.isEnabled = !state.allowlist.isEmpty

        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for entry in state.allowlist {
            let row = NSMenuItem(
                title: entry,
                action: #selector(StatusItemController.untrustEntry(_:)),
                keyEquivalent: ""
            )
            row.target = target
            row.representedObject = entry
            submenu.addItem(row)
        }
        item.submenu = submenu.numberOfItems > 0 ? submenu : nil
        return item
    }

    // MARK: - Row constructors

    /// A read-only row (status line, event rows, warning).
    private func infoRow(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func actionRow(
        _ title: String,
        _ action: Selector,
        _ target: AnyObject?,
        key: String = ""
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target
        return item
    }
}
