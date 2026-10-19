import Darwin
import Foundation

// MARK: - ProcInfo

/// One process as the kernel reports it (spec §4-B).
///
/// `name` is always there: it is `kinfo_proc.p_comm`, which the kernel
/// truncates to `MAXCOMLEN` (16) characters. `path` is **best-effort** — the
/// sysctl table carries no path at all, so it comes from `proc_pidpath`, which
/// can refuse (another user's process, a platform binary, a pid that died
/// between the two calls). A refused path is `nil` and the entry is name-only
/// (spec §4-B: "path ได้เฉพาะ process ของ user ตัวเอง — root-owned agents
/// อาจเห็นแต่ชื่อ").
public struct ProcInfo: Equatable, Sendable {

    /// Kernel pid.
    public let pid: Int32

    /// Kernel process name, truncated to 16 characters (`Google Chrome He`).
    public let name: String

    /// Absolute executable path when the kernel will give it, else `nil`.
    public let path: String?

    public init(pid: Int32, name: String, path: String? = nil) {
        self.pid = pid
        self.name = name
        self.path = path
    }
}

// MARK: - SystemProcesses

/// The real process table: `sysctl KERN_PROC_ALL` for names and pids, plus
/// `proc_pidpath` for the paths (spec §3/§4-B).
///
/// Neither call needs a TCC permission or an entitlement, and neither raises a
/// prompt — which is the whole point of choosing them for the remote tier.
///
/// `list()` is called every 3 seconds for the lifetime of the app, so it is
/// written to be cheap and to degrade rather than fail:
/// - the table is sized once and fetched in one sysctl call, with 16 entries
///   of headroom for processes that appear in between;
/// - a table that grew past the buffer (`ENOMEM`) is retried twice with more
///   room, then the tick simply reports fewer processes instead of spinning;
/// - one 4 KiB path buffer is allocated per call and reused for every pid
///   (`PROC_PIDPATHINFO_MAXSIZE` is what `proc_pidpath` can write); a fresh
///   buffer per process would be megabytes of churn per tick.
public enum SystemProcesses {

    /// Every process the kernel will name, in the order `sysctl` returns it.
    ///
    /// Empty only when the kernel refuses the whole table — which this code
    /// has never seen, and which the watch must treat as "nothing to report"
    /// rather than as "everything is gone".
    public static func list() -> [ProcInfo] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]

        // Call one: the kernel reports how much room the table needs.
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else {
            return []
        }

        let stride = MemoryLayout<kinfo_proc>.stride
        var capacity = size / stride + 16
        var table: [kinfo_proc] = []
        var used = 0

        for _ in 0..<3 {
            var buffer = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
            var length = capacity * stride
            if sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 {
                table = buffer
                used = min(length / stride, capacity)
                break
            }
            // ENOMEM means the table grew between the sizing call and this
            // one; anything else is a refusal worth giving up on. Bounded:
            // this runs forever.
            guard errno == ENOMEM else { return [] }
            capacity += 64
        }
        guard used > 0 else { return [] }

        var pathBuffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))

        var procs: [ProcInfo] = []
        procs.reserveCapacity(used)
        for index in 0..<used {
            let info = table[index]
            let pid = info.kp_proc.p_pid
            procs.append(
                ProcInfo(
                    pid: pid,
                    name: processName(of: info),
                    path: processPath(of: pid, into: &pathBuffer)
                )
            )
        }
        return procs
    }

    /// `p_comm`, NUL-trimmed: at most `MAXCOMLEN` characters of the kernel's
    /// name for the process (long names arrive truncated, see `ProcInfo`).
    ///
    /// `String(decoding:as:)` replaces malformed bytes instead of trapping: a
    /// process name is whatever the process wrote into the kernel, and losing
    /// one name must never take a 3-second poller down.
    private static func processName(of info: kinfo_proc) -> String {
        withUnsafeBytes(of: info.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// `proc_pidpath` into a caller-owned buffer. Best effort: any refusal
    /// (0 or negative return) is a `nil` path, not an error.
    private static func processPath(of pid: Int32, into buffer: inout [UInt8]) -> String? {
        let written = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard written > 0 else { return nil }
        // Stale bytes from a longer path a previous pid left in the buffer sit
        // past `written` and are never read.
        return String(decoding: buffer[0..<Int(written)], as: UTF8.self)
    }
}

// MARK: - ProcessWatch

/// Edge-triggered watch over the system process table (spec §3, §4-B; plan T13).
///
/// The app calls `tick()` every 3 seconds. Each tick lists the table, compares
/// every process against the watchlist and returns **one `RawEvent` per watched
/// name that just appeared** — an edge, never a level: a watched name that was
/// already present last tick is not reported again, and it becomes reportable
/// again only after it has left the table and come back
/// (`testEdgeTriggerEmitsOnce`, `testReappearAfterGoneEmitsAgain`). Without
/// that rule a 3-second poll would emit 20 identical events a minute for a
/// single open remote session.
///
/// **Matching is the Classifier's rule**: a case-insensitive substring test
/// against the process name and, when present, its path, over the watchlist
/// the `names` closure returns. Deliberately the same rule, so a process this
/// watch flags always classifies as REMOTE (unless an org / noise / allowlist
/// rule wins first — spec §5's priority order), and empty entries are ignored
/// exactly as the Classifier ignores them.
///
/// **Identity is the process name**, not the pid. Two live instances of one
/// name are one presence (one event, the first instance the listing returned),
/// and a same-named process that respawns between two ticks is a continuation,
/// not a new appearance: at 3 s cadence that is not an observation the poller
/// can honestly make, whereas pid-set tracking would re-fire every time one of
/// several same-named helpers exits (`remoting_host` spawns one per session),
/// which is noise.
///
/// **Cost.** One tick is `O(#processes × #watchlist)` *substring searches*, and
/// a substring search is the expensive part: ~600 processes against the 12
/// entry default watchlist is ~14k searches, tens of milliseconds, every 3 s.
/// Matching is therefore **memoised per process**: the verdict is a pure
/// function of `(name, path, watchlist)`, so a pid whose name, path and the
/// watchlist are unchanged since the last tick reuses the previous verdict
/// instead of searching again. Steady state costs one dictionary lookup and two
/// string comparisons per process (~0.1 ms for a full table); the full scan is
/// paid once at the first tick and once per new process / config change. The
/// edge state above is untouched by this — it caches a computation, it does not
/// change which processes match.
///
/// **Threading.** Like `Throttler`, this class keeps state across ticks and is
/// deliberately not thread-safe: one owner drives it. In the app the owner is
/// the reader's serial callback queue (see `LogStreamReader.performSerialized`),
/// so the polls serialize with the log lines feeding the same `Pipeline`.
public final class ProcessWatch {

    /// The watchlist, read **on every tick** — never captured once — so a
    /// config reload (T17) changes what is watched without restarting the app.
    private let names: () -> [String]

    /// The process table. Injected so tests drive fixed fixtures; production
    /// is `SystemProcesses.list`.
    private let lister: () -> [ProcInfo]

    /// Source of "now" for the emitted timestamps. Injected so tests pin `ts`;
    /// production is the system clock.
    private let now: () -> Date

    /// The watched names present at the previous tick — the whole edge state.
    /// A name in here is "already reported"; leaving the set is what makes it
    /// reportable again.
    private var present: Set<String> = []

    /// One memoised matching verdict: for this name/path it was `matched`.
    ///
    /// Pids are recycled by the kernel, so the entry is only trusted when the
    /// name *and* path still equal what the verdict was computed from.
    private struct Verdict {
        let name: String
        let path: String?
        let matched: Bool
    }

    /// The verdict cache, keyed by pid (see the class documentation on cost).
    private var verdicts: [Int32: Verdict] = [:]

    /// The lowered watchlist the cached verdicts belong to. A config reload
    /// (T17) changes it, and the whole cache is dropped when it differs —
    /// comparing a handful of short strings once per tick is far cheaper than re-scanning
    /// the table, and it keeps a stale watchlist from answering for a new one.
    private var verdictWatchlist: [String] = []

    /// Upper bound on the cache, so weeks of pid churn cannot grow it without
    /// limit. Far above any real process table; hitting it just costs one
    /// full re-scan.
    private static let verdictCacheLimit = 4096

    public init(
        names: @escaping () -> [String],
        lister: @escaping () -> [ProcInfo] = SystemProcesses.list,
        now: @escaping () -> Date = Date.init
    ) {
        self.names = names
        self.lister = lister
        self.now = now
    }

    /// Polls the process table once.
    ///
    /// Returns at most one event per watched name, in listing order, all
    /// stamped with the same `ts`. The event carries the process name as
    /// `actor` (what the user sees in the evidence log), its pid, and its path
    /// when the kernel gave one.
    public func tick() -> [RawEvent] {
        let watchlist = names().filter { !$0.isEmpty }.map { $0.lowercased() }
        guard !watchlist.isEmpty else {
            // Nothing is being watched, so nothing is present: clearing the
            // state means that if the list comes back, whatever is running
            // re-fires — rather than staying silent because of a match made
            // against a watchlist the user has since replaced.
            present.removeAll()
            verdicts.removeAll()
            verdictWatchlist = watchlist
            return []
        }

        // Matching is pure in (name, path, watchlist): verdicts from the
        // previous tick still hold while the watchlist is the same. This is
        // what keeps a 3 s poll of a full process table cheap — see the class
        // documentation on cost.
        if watchlist != verdictWatchlist || verdicts.count > Self.verdictCacheLimit {
            verdicts.removeAll()
            verdictWatchlist = watchlist
        }

        var matched: Set<String> = []
        var appeared: [ProcInfo] = []
        for proc in lister() {
            let isMatch: Bool
            if let cached = verdicts[proc.pid], cached.name == proc.name, cached.path == proc.path {
                isMatch = cached.matched
            } else {
                isMatch = Self.matches(proc, watchlist: watchlist)
                verdicts[proc.pid] = Verdict(name: proc.name, path: proc.path, matched: isMatch)
            }
            guard isMatch else { continue }
            // The first instance of a name wins; later instances of the same
            // name are the same presence (see the class documentation).
            guard matched.insert(proc.name).inserted else { continue }
            if !present.contains(proc.name) {
                appeared.append(proc)
            }
        }
        present = matched

        let ts = now()
        return appeared.map { proc in
            RawEvent(
                ts: ts,
                source: .processwatch,
                kind: .remoteControlProcess,
                actor: proc.name,
                actorPath: proc.path,
                pid: proc.pid
            )
        }
    }

    /// `true` when any lowercased watchlist entry is a substring of the
    /// process name or of its path. The caller has already dropped empties,
    /// and an empty needle would otherwise match every process.
    private static func matches(_ proc: ProcInfo, watchlist: [String]) -> Bool {
        let name = proc.name.lowercased()
        let path = proc.path?.lowercased()
        return watchlist.contains { needle in
            name.contains(needle) || path?.contains(needle) == true
        }
    }
}
