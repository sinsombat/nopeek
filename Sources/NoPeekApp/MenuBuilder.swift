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
    ///
    /// `events` is the same tray sample `state` was built from — handler order
    /// matches `state.eventRows` one for one — so a row's T21 actions
    /// (`Kill` / `เปิดตำแหน่ง`) always describe the event the row is showing.
    @discardableResult
    func populate(
        _ menu: NSMenu,
        with state: MenuState,
        events: [ClassifiedEvent],
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
        // row of its own when the tray has nothing). A row that has something
        // to act on carries the T21 actions as a submenu — see `eventRow`.
        for (index, row) in state.eventRows.enumerated() {
            let event = index < events.count ? events[index] : nil
            menu.addItem(eventRow(row, event: event, language: language, target: target))
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

        // Spec §6: `Calibration Wizard…` (also the first-launch auto-start).
        menu.addItem(
            actionRow(
                Strings.t("menu.calibration", language),
                #selector(StatusItemController.runCalibration(_:)),
                target
            )
        )

        // Spec §6: `System Checkup…` — the on-demand summary of this Mac's
        // open observation channels (T19).
        menu.addItem(
            actionRow(
                Strings.t("menu.checkup", language),
                #selector(StatusItemController.runCheckup(_:)),
                target
            )
        )

        // Spec §6: `Export รายงาน…` — the evidence export's range presets
        // (T20), straight after the checkup so both "look at this Mac" actions
        // sit together.
        menu.addItem(
            actionRow(
                Strings.t("menu.export", language),
                #selector(StatusItemController.runExport(_:)),
                target
            )
        )

        // Spec §6: `History…` — the evidence log read back as a filterable table
        // (T22, §6b), straight after the export so the two actions that look at
        // the log over time sit together.
        menu.addItem(
            actionRow(
                Strings.t("menu.history", language),
                #selector(StatusItemController.runHistory(_:)),
                target
            )
        )

        // Spec §6: `Settings…` — the config file as a validated form (T23,
        // §6c), the last window row in the spec §6 menu order (after History,
        // before the pause controls).
        menu.addItem(
            actionRow(
                Strings.t("menu.settings", language),
                #selector(StatusItemController.runSettings(_:)),
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

    /// One event row (spec §6).
    ///
    /// Rows with nothing to act on stay what T17 made them: disabled info rows.
    /// A row that can be killed or revealed becomes an **enabled** item whose
    /// submenu carries the actions (spec §6d) — AppKit does not open the submenu
    /// of a disabled item, so greying the parent would hide the actions
    /// entirely. The action's `representedObject` is the row's `KillTarget`,
    /// which is what the selectors act on.
    private func eventRow(
        _ title: String,
        event: ClassifiedEvent?,
        language: Language,
        target: StatusItemController
    ) -> NSMenuItem {
        let item = infoRow(title)
        guard let event else { return item }

        let actions = NSMenu()
        actions.autoenablesItems = false

        if event.offersKillAction {
            actions.addItem(
                actionRow(
                    Strings.t("menu.event.kill", language),
                    #selector(StatusItemController.killRow(_:)),
                    target,
                    represented: KillTarget(event)
                )
            )
        }
        if event.offersLocationAction {
            actions.addItem(
                actionRow(
                    Strings.t("menu.event.reveal", language),
                    #selector(StatusItemController.revealRow(_:)),
                    target,
                    represented: KillTarget(event)
                )
            )
        }

        guard actions.numberOfItems > 0 else { return item }
        item.isEnabled = true
        item.submenu = actions
        return item
    }

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
        key: String = "",
        represented: Any? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target
        item.representedObject = represented
        return item
    }
}
