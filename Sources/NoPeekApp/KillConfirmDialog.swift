import AppKit
import Darwin
import PWCore

// MARK: - ProcessLocation (AppKit half)

/// Finder reveal, the one part of `ProcessLocation` that needs AppKit.
///
/// The resolver itself lives in PWCore (AppKit-free, unit-tested); this
/// extension is the pinned T21 spelling the app layer uses, and it keeps the
/// `NSWorkspace` call where the UI is.
extension ProcessLocation {

    /// Shows `url` in a Finder window with the item selected — the same call
    /// the T20 export panel's `เปิดใน Finder` uses, so "reveal" means one thing
    /// in this app.
    @MainActor
    static func openInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Reveals the best location for `target` (the outer `.app` when the path
    /// runs through a bundle, else the executable). Returns `false` when there
    /// is nothing to reveal — the caller does not have to resolve twice to find
    /// that out.
    @discardableResult
    @MainActor
    static func openInFinder(for target: KillTarget) -> Bool {
        guard let url = revealURL(for: target.actorPath, pid: target.pid) else { return false }
        openInFinder(url)
        return true
    }
}

// MARK: - KillConfirmDialog

/// The manual kill's two modals (spec §6d): the confirmation, and the
/// "root-owned — open the macOS admin prompt?" follow-up.
///
/// Both are `NSAlert`s on the main thread, like every other dialog in the app
/// (`About`, the checkup's errors, the config-failure alert). All copy comes
/// from `Strings` in the configured language (spec §10); the one exception is
/// the macOS admin password dialog itself, which is the system's own UI for the
/// `osascript` command `AdminKiller` runs.
@MainActor
enum KillConfirmDialog {

    /// The spec §6d confirmation: name / location / pid, the `Force (SIGKILL)`
    /// checkbox, and the corporate-policy warning.
    ///
    /// - Returns: `true` when the user asked for the force path, `false` for
    ///   the ordinary `SIGTERM`-first path, and `nil` when they cancelled —
    ///   nothing is attempted in that case, so nothing is logged.
    ///
    /// `เปิดตำแหน่ง` is the third button and it does **not** decide anything:
    /// the dialog is simply presented again after the reveal, so nobody has to
    /// reopen the menu to still be able to answer the question.
    static func present(target: KillTarget, language: Language) -> Bool? {
        let location = ProcessLocation.revealURL(for: target.actorPath, pid: target.pid)?.path
            ?? Strings.t("kill.location.unknown", language)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = Strings.t("kill.title", language)
        alert.informativeText = String(
            format: Strings.t("kill.detail", language),
            target.actor,
            location,
            target.pid.map(String.init) ?? "—"
        ) + "\n\n" + Strings.t("kill.policy", language)

        alert.addButton(withTitle: Strings.t("kill.button.kill", language))
        alert.addButton(withTitle: Strings.t("kill.button.cancel", language))
        alert.addButton(withTitle: Strings.t("menu.event.reveal", language))
        // Nothing to kill without a pid: the row only offers the action when
        // there is one, and a notification action could still arrive without.
        alert.buttons.first?.isEnabled = target.pid != nil

        let force = NSButton(
            checkboxWithTitle: Strings.t("kill.force", language),
            target: nil,
            action: nil
        )
        force.state = .off
        alert.accessoryView = force

        NSApp.activate()
        while true {
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                return force.state == .on
            case .alertThirdButtonReturn:
                ProcessLocation.openInFinder(for: target)
                continue
            default:
                return nil // ยกเลิก / the window was closed
            }
        }
    }

    /// The EPERM follow-up (spec §6d): `true` when the user agreed to the macOS
    /// admin prompt, `false` when they declined — declining is recorded in the
    /// evidence log like any other outcome.
    ///
    /// **Manual only.** Auto-kill never calls this; a root-owned process simply
    /// stays alive with a `process-kill` line saying so and one notification
    /// (spec §6d).
    static func presentAdminPrompt(language: Language) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = Strings.t("kill.admin.ask.title", language)
        alert.informativeText = Strings.t("kill.admin.ask.body", language)
        alert.addButton(withTitle: Strings.t("kill.admin.ask.ok", language))
        alert.addButton(withTitle: Strings.t("kill.button.cancel", language))

        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }
}

// MARK: - AdminKiller

/// The macOS admin prompt for a kill that came back `EPERM` (spec §6d,
/// **manual only**).
///
/// `/usr/bin/osascript -e 'do shell script "kill -<sig> <pid>" with administrator
/// privileges'` raises the system's own password dialog for that one command;
/// the user can — and in the acceptance test *does* — cancel it. This is an
/// authorisation dialog for a process this user owns, not a TCC permission:
/// NoPeek requests no TCC permission anywhere (spec §9/§13), and the app never
/// holds the privilege it grants.
///
/// **No injection surface.** The command is built from values this app derived
/// itself, never from text:
/// - the pid is interpolated from an `Int32` — decimal digits (and, for the
///   non-positive values this method refuses outright, a minus sign) and
///   nothing else, so no string from a log line, a config file or a process
///   name can reach the shell;
/// - the signal must be one of the two constants this app ever sends
///   (`SIGTERM`/`SIGKILL`); anything else is refused before `osascript` is
///   considered;
/// - the executable is a fixed absolute path, and the shell string is passed as
///   a single `-e` argument, never through a shell of our own.
enum AdminKiller {

    /// Runs the elevated kill and reports whether `kill(1)` exited 0 — which is
    /// also the answer for "the user cancelled the password dialog" (`osascript`
    /// exits non-zero) and for "the process was already gone".
    ///
    /// Blocking: waits for the system dialog and the kill. Call it off the main
    /// thread (the app uses its kill queue); the dialog itself is drawn by
    /// macOS, so nothing in this process needs to keep running.
    static func killWithPrivileges(pid: Int32, signal: Int32) -> Bool {
        guard pid > 0 else { return false }
        guard signal == SIGTERM || signal == SIGKILL else { return false }

        let command = "kill -\(signal) \(pid)"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \"\(command)\" with administrator privileges"]
        // The dialog is the user's interface; osascript's own summary ("User
        // canceled.") is not worth inheriting the app's stdio for.
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
