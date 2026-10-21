import Darwin
import Foundation

// MARK: - LiveProcessNaming

/// Names a pid from the kernel for log-line attribution (spec §4-E, v1.1).
///
/// The microphone signal is logged by `coreaudiod` but belongs to the recorder
/// client it names. Turning that client pid into an actor needs a fresh read —
/// the line carries only the number — so this is the resolver behind
/// `LogLineParser`'s `resolveClient` default:
///
/// 1. `proc_pidpath` gives the executable path; the display name is its
///    basename, the same convention the log-stream actor uses for
///    `processImagePath`.
/// 2. When the path is unavailable (another user's process, a pid that just
///    exited, a platform binary the kernel will not path), `sysctl
///    KERN_PROC_PID` supplies the kernel's short name (`p_comm`, truncated to
///    `MAXCOMLEN`).
/// 3. Neither answers → `nil`: the parser then attributes the event to the
///    signal (`"mic"`) rather than guessing.
///
/// Read-only, no TCC, no `proc_name` (which is silent for other users'
/// processes — `p_comm` is not). Kept separate from `ProcessWatch` /
/// `KillController` on purpose: their readers are tuned to bulk tables and
/// pid-reuse guards, and this one is a single-pid lookup for a log line.
public enum LiveProcessNaming {

    /// The client's display name and executable path, or `nil` when the pid
    /// cannot be named.
    public static func resolve(_ pid: Int32) -> (name: String, path: String?)? {
        guard pid > 0 else { return nil }

        if let path = executablePath(pid) {
            let name = (path as NSString).lastPathComponent
            if !name.isEmpty {
                return (name: name, path: path)
            }
        }

        if let name = kernelName(pid) {
            return (name: name, path: nil)
        }

        return nil
    }

    /// `proc_pidpath(2)` — the kernel's own path for a live pid. Best effort:
    /// any refusal is `nil`, exactly like `ProcessLocation.systemPath`.
    static func executablePath(_ pid: Int32) -> String? {
        guard pid > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let written = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard written > 0 else { return nil }

        let path = String(decoding: buffer[0..<Int(written)], as: UTF8.self)
        return path.isEmpty ? nil : path
    }

    /// `kinfo_proc.kp_proc.p_comm`, NUL-trimmed: the kernel's short name for
    /// any live pid (root's included), truncated to `MAXCOMLEN` characters.
    static func kernelName(_ pid: Int32) -> String? {
        guard pid > 0 else { return nil }

        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else {
            return nil
        }

        // `String(decoding:as:)` replaces malformed bytes instead of trapping:
        // a process name is whatever the process wrote into the kernel, and a
        // bad name must never take the log parser down.
        let name = withUnsafeBytes(of: info.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return name.isEmpty ? nil : name
    }
}
