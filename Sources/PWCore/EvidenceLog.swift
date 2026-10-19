import Foundation

// MARK: - EvidenceLog

/// The append-only evidence log on disk (spec §8, plan T8).
///
/// One file per day — `events-YYYY-MM-DD.ndjson` — holding one flat JSON
/// `ClassifiedEvent` per line, with a trailing newline (the schema is pinned by
/// `ModelsTests.testClassifiedEventEncodesAsFlatEvidenceLogLine`; nothing here
/// changes the line format). A new file is started by the calendar turning
/// over, so rotation costs nothing when nothing happens.
///
/// **Days are local days.** A file is named for the event's day in the
/// machine's current timezone, not UTC, so "the file for today" is today as the
/// user's Mac shows it, and it lines up with the `+07:00`-style local offsets
/// the spec's timestamps carry. A timezone change can split one calendar day
/// across two files; reading and purging apply the same local-day rule, so no
/// event is lost and none is mis-aged.
///
/// The log is **best-effort**: `append` swallows write failures instead of
/// throwing. Evidence logging is secondary to monitoring — a full disk or a
/// sandbox denial must never take a watcher down — but it does mean a writing
/// failure is silent, so the caller cannot treat a successful `append` call as
/// proof a line landed.
///
/// Not thread-safe: one owner drives an instance (the app's single event
/// pipeline, T11). Tests drive one directly.
public final class EvidenceLog {

    // MARK: - Configuration

    /// Directory the `events-*.ndjson` files live in. Production supplies
    /// `~/Library/Logs/NoPeek`; tests use a throwaway directory under
    /// `FileManager.temporaryDirectory` (never a TCC-sensitive path).
    public let directory: URL

    /// How many days of files `purgeOldFiles()` keeps, today included
    /// (spec §7 `logRetentionDays`, default 30).
    public let retentionDays: Int

    /// The clock lifecycle events and retention read. Injected so tests
    /// control time exactly; `append` itself files by the event's timestamp.
    private let now: () -> Date

    private let fileManager = FileManager.default

    /// On-disk naming: `events-YYYY-MM-DD.ndjson`. Only files matching this
    /// scheme are ever read, aged or deleted — anything else in the directory
    /// is left alone.
    private static let namePrefix = "events-"
    private static let nameSuffix = ".ndjson"

    // MARK: - Life cycle

    /// - Parameters:
    ///   - directory: where the log files live; created on first `append`.
    ///   - retentionDays: days kept by `purgeOldFiles()` (spec §7: 30).
    ///   - now: source of "now" for `appendRaw` and `purgeOldFiles`; defaults
    ///     to the system clock.
    public init(directory: URL, retentionDays: Int = 30, now: @escaping () -> Date = Date.init) {
        self.directory = directory
        self.retentionDays = retentionDays
        self.now = now
    }

    // MARK: - Appending

    /// Appends one classified event as a line to the file for the event's
    /// local day, creating the directory and the file when they are missing.
    ///
    /// Best-effort: see the class documentation.
    public func append(_ e: ClassifiedEvent) {
        guard let json = try? JSONEncoder().encode(e) else { return }
        append(encoded: json, on: e.event.ts)
    }

    /// Appends a lifecycle event of the app itself (`monitor-started`,
    /// `monitor-degraded`, `monitor-recovered`, `monitor-gap`,
    /// `config-reloaded`, `calibration-result`, `checkup-run`, `export-created`,
    /// `process-kill`, `heartbeat` — spec §8): `ts` is the injected clock and
    /// `source` is `.system`.
    ///
    /// Lifecycle lines carry tier `.systemNoise` and reason `"lifecycle"`.
    /// Neither is in spec §5's tier table (the table's tiers describe observed
    /// actors), and `.systemNoise` is the honest slot for "system chatter that
    /// is logged but never notified": a heartbeat or `monitor-started` must not
    /// put the menu-bar icon into its "being watched" state or raise a
    /// notification. `monitor-gap` is the exception in spirit — T24 notifies
    /// for it directly, bypassing the tier pipeline — but its log line still
    /// reads as system chatter, which is what it is.
    ///
    /// `rawSummary` is the outcome of a kill (`process-kill`, spec §6d) — the
    /// signal that was delivered, the EPERM, the elevation result, the guard
    /// halt. `actor` is the process that was killed, so the line names both the
    /// subject and the outcome. Every other lifecycle event leaves it `nil`,
    /// which the encoder then omits (the spec §8 line shape is unchanged).
    public func appendRaw(kind: EventKind, actor: String = "nopeek", rawSummary: String? = nil) {
        let raw = RawEvent(
            ts: now(),
            source: .system,
            kind: kind,
            actor: actor,
            rawSummary: rawSummary
        )
        append(ClassifiedEvent(event: raw, tier: .systemNoise, reason: "lifecycle"))
    }

    private func append(encoded eventJSON: Data, on date: Date) {
        guard createDirectoryIfNeeded() else { return }

        let url = directory.appendingPathComponent(fileName(for: date))
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }

        // One JSON object per line, trailing newline. The handle is opened and
        // closed per append: it costs two syscalls per event (tens per second
        // at most) and no append ever holds an open descriptor to a file that
        // rotation or purge may be changing.
        var line = eventJSON
        line.append(0x0A)

        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            // Best effort: a failed append must not take a watcher down.
        }
    }

    private func createDirectoryIfNeeded() -> Bool {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Last activity

    /// Timestamp of the last line of the newest file, or `nil` when the
    /// directory holds no log file yet.
    ///
    /// "Newest" is the day in the file name: rotation is name-based, so a
    /// restore or backup that touches an older file must not make it win. When
    /// the last line cannot be decoded — a crash mid-append leaves a torn line
    /// — the file's modification date stands in for it, and a file whose name
    /// does not parse at all is aged by its modification date too.
    ///
    /// This is what `GapDetector` (T9) compares against the current time at
    /// startup; the heartbeat lines (`appendRaw(kind: .heartbeat)`, every 5
    /// minutes, T24) exist to keep it fresh while nothing is being captured.
    public func lastActivity() -> Date? {
        guard let newest = logFiles().max(by: { $0.day < $1.day }) else { return nil }

        if let line = lastLine(of: newest.url),
           let event = try? JSONDecoder().decode(ClassifiedEvent.self, from: line) {
            return event.event.ts
        }
        return modificationDate(of: newest.url)
    }

    /// The last line of `url`, read from a bounded tail so a day-sized file
    /// never has to fit in memory. `nil` when the file cannot be read or holds
    /// no line at all.
    private func lastLine(of url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let size = try? handle.seekToEnd(), size > 0 else { return nil }
        let chunkSize: UInt64 = 64 * 1024
        let start = size > chunkSize ? size - chunkSize : 0

        do {
            try handle.seek(toOffset: start)
        } catch {
            return nil
        }
        guard let tail = try? handle.readToEnd(), !tail.isEmpty else { return nil }

        // A chunk with no newline at all, taken from the middle of the file,
        // is the inside of one over-long line: only a full read can find where
        // that line began. (Real lines are ~200 bytes; this is the degenerate
        // case, not the normal one.)
        if start > 0 && !tail.contains(0x0A) {
            return (try? Data(contentsOf: url))?.split(separator: 0x0A).last
        }
        return tail.split(separator: 0x0A).last // empty trailing lines dropped
    }

    // MARK: - Retention

    /// Deletes log files that have fallen out of the retention window.
    ///
    /// Retention is counted in whole local days: with N days kept, the files
    /// for today and the N-1 days before it survive. A file's day comes from
    /// its name, or from its modification day when the name does not parse.
    /// The count is clamped to at least 1 so the file currently being appended
    /// to can never be purged out from under the app. Only `events-*.ndjson`
    /// files are considered; everything else in the directory is left
    /// untouched.
    ///
    /// `keepingDays` overrides the instance's own `retentionDays` (T23: the
    /// Settings window's `Purge now` passes the value **saved in the config**,
    /// which a live change may have moved on from — this instance's
    /// `retentionDays` is only the value it was built with). `nil` — the
    /// default, and every pre-T23 call site — keeps the original semantics.
    ///
    /// Called at startup (T24) before the gap check, so the gap check does not
    /// see files it is about to delete.
    public func purgeOldFiles(keepingDays days: Int? = nil) {
        let calendar = Calendar.current
        let retained = max(days ?? retentionDays, 1)
        guard let cutoff = calendar.date(
            byAdding: .day,
            value: -(retained - 1),
            to: calendar.startOfDay(for: now())
        ) else { return }

        for file in logFiles() where file.day < cutoff {
            try? fileManager.removeItem(at: file.url)
        }
    }

    // MARK: - Range read

    /// Every event with `ts` in `[from, to]` — bounds inclusive — in file
    /// order, then line order within a file (append order, which is not
    /// guaranteed to be timestamp order).
    ///
    /// Only files whose day can hold a matching timestamp are opened: a file's
    /// name is the local day of the events inside it, so the files for the
    /// days of `from` and `to` bound the search. Lines that do not decode as
    /// `ClassifiedEvent` — a torn append, a foreign line — are skipped
    /// individually rather than failing the whole read (the log is read while
    /// it is being written, spec §4). An inverted range matches nothing.
    public func read(from: Date, to: Date) -> [ClassifiedEvent] {
        matching(from: from, to: to).map(\.event)
    }

    /// The raw, **undecoded bytes** of every line whose event `ts` falls in
    /// `[from, to]`, in the same order as `read(from:to:)` — the exporter
    /// (T20) copies this verbatim instead of re-encoding, so the ndjson
    /// artefact is the log's own spelling of the range.
    ///
    /// The window rule is `read`'s, applied to the same lines: a line is
    /// included only when it decodes *and* its timestamp is in range (a torn
    /// or foreign line has no timestamp to filter by, and is skipped exactly as
    /// `read` skips it). The line's trailing newline is not part of the
    /// returned bytes: it is the separator between lines, not line content.
    public func rawLines(from: Date, to: Date) -> [Data] {
        matching(from: from, to: to).map(\.bytes)
    }

    /// Both views of one range from a **single pass** over the day files: the
    /// bytes of each line that belongs to the window and the event they decode
    /// to. `read` and `rawLines` are this, seen one way each — one loop, so the
    /// two can never disagree about which lines are in a range or in what
    /// order they come back.
    private func matching(from: Date, to: Date) -> [(bytes: Data, event: ClassifiedEvent)] {
        guard from <= to else { return [] }

        let calendar = Calendar.current
        let firstDay = calendar.startOfDay(for: from)
        let lastDay = calendar.startOfDay(for: to)
        let decoder = JSONDecoder()

        var matches: [(bytes: Data, event: ClassifiedEvent)] = []
        for file in logFiles().sorted(by: { $0.day < $1.day }) {
            guard file.day >= firstDay, file.day <= lastDay else { continue }
            guard let data = try? Data(contentsOf: file.url) else { continue }
            for line in data.split(separator: 0x0A) {
                guard let event = try? decoder.decode(ClassifiedEvent.self, from: line) else { continue }
                if event.event.ts >= from && event.event.ts <= to {
                    matches.append((bytes: Data(line), event: event))
                }
            }
        }
        return matches
    }

    // MARK: - File discovery

    /// One log file with the local day it covers.
    private struct LogFile {
        let url: URL
        /// From the name when it parses, else the file's modification day.
        let day: Date
    }

    /// The `events-*.ndjson` files in the directory, in directory-listing
    /// order; callers sort when order matters. An unreadable or missing
    /// directory reads as "no files".
    private func logFiles() -> [LogFile] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return []
        }

        return names.compactMap { name in
            guard name.hasPrefix(Self.namePrefix), name.hasSuffix(Self.nameSuffix) else {
                return nil
            }
            let url = directory.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue
            else { return nil }

            guard let day = Self.day(fromFileName: name) ?? modificationDay(of: url) else {
                return nil
            }
            return LogFile(url: url, day: day)
        }
    }

    /// The local day of the `YYYY-MM-DD` in an `events-…` file name, or `nil`
    /// when the name does not carry a well-formed day.
    private static func day(fromFileName name: String) -> Date? {
        let core = String(name.dropFirst(namePrefix.count).dropLast(nameSuffix.count))
        let formatter = dayFormatter()
        // The round-trip check rejects names the parser would otherwise accept
        // leniently (`2026-1-7`, `2026-10-17junk`, …), so a malformed name
        // falls through to the modification-date path instead of silently
        // dating a file wrong.
        guard let date = formatter.date(from: core), formatter.string(from: date) == core else {
            return nil
        }
        return Calendar.current.startOfDay(for: date)
    }

    // MARK: - Day formatting

    /// `events-YYYY-MM-DD.ndjson` for the local day of `date`.
    ///
    /// See the class documentation for the local-time choice; reading and
    /// purging parse the same `yyyy-MM-dd` in the same timezone, so the three
    /// operations always agree on what day a file is.
    private func fileName(for date: Date) -> String {
        "\(Self.namePrefix)\(Self.dayString(for: date))\(Self.nameSuffix)"
    }

    private static func dayString(for date: Date) -> String {
        dayFormatter().string(from: date)
    }

    /// `yyyy-MM-dd` in the machine's current timezone, POSIX so the digits do
    /// not follow the user's locale. Built per call: `DateFormatter` is not
    /// `Sendable`, and this is not a hot path (one file name per append).
    private static func dayFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    // MARK: - File metadata

    private func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private func modificationDay(of url: URL) -> Date? {
        modificationDate(of: url).map { Calendar.current.startOfDay(for: $0) }
    }
}
