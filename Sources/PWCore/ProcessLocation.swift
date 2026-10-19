import Darwin
import Foundation

// MARK: - ProcessLocation

/// Turns "who did it" into "what to show in Finder" (spec §6d `เปิดตำแหน่ง`,
/// plan T21).
///
/// The rule is deliberately narrow, and it is the rule the *user* wants: an
/// event's `actorPath` is usually the executable inside an `.app`, and a user
/// asked to "open the location" of `Google Chrome Helper` wants Chrome.app in a
/// Finder window, not a Mach-O buried four directories deep. So:
///
/// 1. a path that runs **through** a bundle resolves to the **outermost**
///    `.app` in it (nested helper apps belong to the app that owns them);
/// 2. anything else resolves to the executable file itself;
/// 3. no path — `<private>` redaction, a truncated line, a name-only
///    `ProcInfo` — falls back to the pid, resolved through `systemPath`;
/// 4. nothing usable → `nil`, and the caller offers no `เปิดตำแหน่ง` action.
///
/// **Pure path logic on purpose.** Nothing here checks that the file still
/// exists or that the pid is alive: a reveal is a navigation aid, and a stale
/// path that Finder cannot show is not worth a different outcome in the layer
/// that decides *whether* to offer the action. Tests pin the mapping with
/// literal paths; only the smoke test touches the real process table.
///
/// The `NSWorkspace` half of the feature (`openInFinder`) lives in the app
/// target (`KillConfirmDialog.swift`), so this module stays AppKit-free and its
/// resolver stays unit-testable (plan T21).
public enum ProcessLocation {

    /// The URL worth revealing for one event's process, or `nil` when there is
    /// nothing to reveal.
    ///
    /// - Parameters:
    ///   - actorPath: the executable path the watcher captured, if any.
    ///   - pid: the process id the watcher captured, if any.
    ///   - resolver: pid → executable path. Injected so tests never touch a
    ///     real process; production is `systemPath` (`proc_pidpath`).
    public static func revealURL(
        for actorPath: String?,
        pid: Int32?,
        resolver: @escaping (Int32) -> String? = ProcessLocation.systemPath
    ) -> URL? {
        let path: String?
        if let actorPath, !actorPath.isEmpty {
            path = actorPath
        } else if let pid {
            path = resolver(pid)
        } else {
            path = nil
        }

        guard let path, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: bundlePath(containing: path) ?? path)
    }

    /// The real resolver: `proc_pidpath(2)`, the kernel's own path for a pid.
    ///
    /// Best effort by design — the call refuses for another user's process, a
    /// platform binary, or a pid that died in between, exactly like
    /// `SystemProcesses`' use of it (spec §4-B). The buffer is decoded with
    /// `String(decoding:as:)`, so malformed bytes degrade to replacement
    /// characters instead of trapping on a process name nobody controls.
    public static func systemPath(_ pid: Int32) -> String? {
        guard pid > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let written = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard written > 0 else { return nil }

        let path = String(decoding: buffer[0..<Int(written)], as: UTF8.self)
        return path.isEmpty ? nil : path
    }

    // MARK: - Bundle extraction

    /// The outermost `.app` directory `path` runs through, or `nil` when the
    /// path is not inside a bundle.
    ///
    /// The suffix match is case-insensitive (`.APP` is still a bundle on a
    /// case-insensitive filesystem) and anchored: a directory merely *named*
    /// `apples` is not a bundle.
    private static func bundlePath(containing path: String) -> String? {
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let index = components.firstIndex(where: { $0.lowercased().hasSuffix(".app") }) else {
            return nil
        }
        return "/" + components[...index].joined(separator: "/")
    }
}
