import Foundation

// MARK: - ExportResult

/// What one export produced (plan T20; spec §9 `Exporter`, acceptance 12).
///
/// The three URLs share one timestamp (`NoPeek-export-YYYYMMDD-HHMM.<ext>`), so
/// they group as one export in Finder and in a report's filename. `eventCount`
/// is the number of **evidence-log lines** the range covers — the same count
/// the Markdown header states and the CSV's row count minus its header.
public struct ExportResult: Equatable, Sendable {

    /// The Markdown summary: range, per-tier counts, and the full ORG/REMOTE
    /// sections.
    public let markdownURL: URL

    /// The CSV table: one row per evidence line, columns pinned by
    /// `Exporter.csvHeader`.
    public let csvURL: URL

    /// The verbatim copy of the range's raw ndjson lines.
    public let ndjsonURL: URL

    /// Evidence-log lines in the exported range.
    public let eventCount: Int

    public init(markdownURL: URL, csvURL: URL, ndjsonURL: URL, eventCount: Int) {
        self.markdownURL = markdownURL
        self.csvURL = csvURL
        self.ndjsonURL = ndjsonURL
        self.eventCount = eventCount
    }
}

// MARK: - Exporter

/// The evidence exporter (plan T20; spec §9): a date range in, three artifacts
/// out.
///
/// | Artifact | Content | Source |
/// |---|---|---|
/// | `.md` | range + per-tier counts, full ORG/REMOTE sections, the data source | `EvidenceLog.read(from:to:)` (typed view) |
/// | `.csv` | one row per line: `ts,kind,actor,actorPath,pid,tier,reason,count,source` | `EvidenceLog.read(from:to:)` (typed view) |
/// | `.ndjson` | the range's raw log lines | `EvidenceLog.rawLines(from:to:)` (verbatim bytes) |
///
/// The copy is deliberately **not** a re-encoding of the parsed events: the
/// ndjson artefact is what the log actually holds, byte for byte, so it can be
/// diffed against the day files.
///
/// **Where the files go (ruling F4).** `~/Library/Logs/NoPeek/exports`, created
/// on demand — never `~/Downloads`, which would raise macOS's folder-permission
/// prompt for an app that takes no TCC permission of its own (spec §9/§13).
/// The export panel offers "reveal in Finder" instead, so the user moves the
/// files wherever they like.
///
/// **Ownership.** The exporter only *reads* the log: it appends nothing, purges
/// nothing and writes only inside its own `outputDirectory`. That is what makes
/// it safe to run while the pipeline is watching — a line appended while an
/// export reads carries the moment it was appended, which for the panel's
/// windows (they end at the button press) is after the range and outside the
/// report. The typed view and the verbatim copy are two sequential reads of
/// that window; a delayed append carrying an *older* timestamp could in
/// principle land between them and appear in the copy alone (the copy is the
/// fresher read, and the raw artefact is the wider one).
///
/// **Threading (`@unchecked Sendable`).** The panel runs an export on a
/// detached task so a month of log files cannot freeze the window, which needs
/// this type to be sendable — and it is, because the class holds no mutable
/// state of its own (`log`, `outputDirectory` and `now` are set once) and
/// `EvidenceLog.read`/`rawLines` keep everything they use in locals: no
/// instance state is touched, so concurrent reads are independent, and a read
/// racing the pipeline's append is the situation T8 already pins a rule for (a
/// torn last line is skipped, spec §4). The one thing not to do with an
/// instance is mutate the log through it — it has no API for that.
///
/// **One timestamp per export.** `now()` is read once and stamps all three
/// names, so the three files of one export always agree; two exports inside the
/// same minute overwrite each other's files, which the pinned
/// `NoPeek-export-YYYYMMDD-HHMM` naming accepts.
public final class Exporter: @unchecked Sendable {

    // MARK: - Configuration

    /// `~/Library/Logs/NoPeek/exports` — beside the log it reports on, and
    /// outside every TCC-protected folder (ruling F4).
    public static var defaultOutputDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/NoPeek/exports")
    }

    /// The CSV's pinned column order (plan T20 interface).
    public static let csvHeader = "ts,kind,actor,actorPath,pid,tier,reason,count,source"

    /// The evidence log this exporter reads. Read-only here; the collector's
    /// single writer stays the event pipeline.
    private let log: EvidenceLog

    /// Where the three files are written; created on demand by `export`.
    public let outputDirectory: URL

    /// The export's clock. Read **once** per export, so the three file names
    /// share one timestamp; injected so tests pin it.
    private let now: () -> Date

    private let fileManager = FileManager.default

    /// - Parameters:
    ///   - log: the evidence log to read (production: `AppController`'s).
    ///   - outputDirectory: destination, created on demand (default:
    ///     `defaultOutputDirectory`).
    ///   - now: the export's timestamp — file names and the report's
    ///     "Exported" line.
    public init(
        log: EvidenceLog,
        outputDirectory: URL = Exporter.defaultOutputDirectory,
        now: @escaping () -> Date = Date.init
    ) {
        self.log = log
        self.outputDirectory = outputDirectory
        self.now = now
    }

    // MARK: - Export

    /// Writes the three artifacts for `[from, to]` (bounds inclusive, local
    /// days) and returns them with the line count.
    ///
    /// An empty or inverted range is not an error: all three files are still
    /// written (a header-only CSV, an empty copy), so a caller never has to
    /// special-case "nothing happened" before opening the summary.
    public func export(from: Date, to: Date) throws -> ExportResult {
        // The typed view first, the raw copy second: the copy may then be a
        // line *ahead* of the summary rather than behind it, and the raw
        // artefact is the one allowed to be wider (see the class note).
        let events = log.read(from: from, to: to)
        let lines = log.rawLines(from: from, to: to)
        let exportedAt = now()

        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let stem = "NoPeek-export-\(Self.stamp(exportedAt))"
        let markdownURL = outputDirectory.appendingPathComponent("\(stem).md")
        let csvURL = outputDirectory.appendingPathComponent("\(stem).csv")
        let ndjsonURL = outputDirectory.appendingPathComponent("\(stem).ndjson")

        try Data(Self.markdown(
            from: from,
            to: to,
            events: events,
            exportedAt: exportedAt,
            sourcePath: log.directory.path
        ).utf8).write(to: markdownURL, options: .atomic)

        try Data(Self.csv(events).utf8).write(to: csvURL, options: .atomic)

        try Self.ndjson(lines).write(to: ndjsonURL, options: .atomic)

        return ExportResult(
            markdownURL: markdownURL,
            csvURL: csvURL,
            ndjsonURL: ndjsonURL,
            eventCount: events.count
        )
    }

    // MARK: - Markdown

    /// The whole report. English structure on purpose: the file is an artefact
    /// meant to be handed to someone else (an admin, a security team), not app
    /// UI — the CSV's columns and the log's JSON keys are English for the same
    /// reason, and timestamps stay Gregorian (`en_US_POSIX`) so they mean one
    /// thing to every reader.
    private static func markdown(
        from: Date,
        to: Date,
        events: [ClassifiedEvent],
        exportedAt: Date,
        sourcePath: String
    ) -> String {
        var out = "# NoPeek export\n\n"
        out += "- Range: \(human(from)) — \(human(to)) (local time, both ends inclusive)\n"
        out += "- Exported: \(human(exportedAt))\n"
        out += "- Events: \(events.count)\n"
        out += "- By tier: \(tierCounts(events))\n"
        out += "- Source: this Mac's own evidence log at \(sourcePath)"
        out += " — only what NoPeek observed while it was running\n"

        for tier in [Tier.org, .remote] {
            let selected = events.filter { $0.tier == tier }
            out += "\n## \(tier.rawValue) events (\(selected.count))\n\n"
            if selected.isEmpty {
                out += "_None in this range._\n"
            } else {
                for event in selected {
                    out += "- \(line(for: event))\n"
                }
            }
        }
        return out
    }

    /// One event as a single bullet: the same fields the CSV carries, shaped so
    /// a human reads it and a script can still split on " — ".
    private static func line(for event: ClassifiedEvent) -> String {
        let raw = event.event
        var parts = [human(raw.ts), raw.actor, raw.kind.rawValue]
        if let pid = raw.pid {
            parts.append("pid \(pid)")
        }
        parts.append("count \(event.count)")
        parts.append("reason \(oneLine(event.reason))")
        if let path = raw.actorPath {
            parts.append(oneLine(path))
        }
        if let summary = raw.rawSummary {
            parts.append("raw \"\(oneLine(summary))\"")
        }
        return parts.joined(separator: " — ")
    }

    /// `ORG 2 · REMOTE 0 · …` for every tier, in `Tier.allCases` order, so a
    /// zero is visible instead of a tier silently missing. The counts are log
    /// lines per tier (the throttler's collapsed bursts stay in the `count`
    /// column, not here).
    private static func tierCounts(_ events: [ClassifiedEvent]) -> String {
        Tier.allCases
            .map { tier in "\(tier.rawValue) \(events.count { $0.tier == tier })" }
            .joined(separator: " · ")
    }

    /// Free text can carry a line break (a `rawSummary` is a log excerpt, a
    /// path is whatever the system printed). A report bullet is one line, so
    /// breaks become spaces rather than splitting the bullet in two.
    private static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    // MARK: - CSV

    private static func csv(_ events: [ClassifiedEvent]) -> String {
        var out = csvHeader + "\n"
        for event in events {
            let raw = event.event
            let fields = [
                ISO8601Timestamp.string(from: raw.ts),
                raw.kind.rawValue,
                raw.actor,
                raw.actorPath ?? "",
                raw.pid.map(String.init) ?? "",
                event.tier.rawValue,
                event.reason,
                String(event.count),
                raw.source.rawValue,
            ]
            out += fields.map(quoted).joined(separator: ",") + "\n"
        }
        return out
    }

    /// RFC 4180 field quoting: only quote what needs it (a comma, a quote, a
    /// line break), and double the inner quotes.
    private static func quoted(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"")
            || field.contains("\n") || field.contains("\r")
        else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: - ndjson copy

    /// The raw lines, one per line with a trailing newline; no trailing newline
    /// when there are no lines, so an empty range is an empty file.
    private static func ndjson(_ lines: [Data]) -> Data {
        var data = Data()
        data.reserveCapacity(lines.reduce(0) { $0 + $1.count + 1 })
        for line in lines {
            data.append(line)
            data.append(0x0A)
        }
        return data
    }

    // MARK: - Formatting

    /// `yyyyMMdd-HHmm` in the machine's local zone, POSIX so the digits never
    /// follow a locale's calendar (Thai's Buddhist year would rename the files
    /// and stop them sorting with the log's own `yyyy-MM-dd` day names).
    private static func stamp(_ date: Date) -> String {
        formatter("yyyyMMdd-HHmm").string(from: date)
    }

    /// Human-readable local time with its UTC offset, e.g.
    /// `2026-10-18 14:05:00 +07:00`: a report that travels should not depend on
    /// the reader's timezone guess.
    private static func human(_ date: Date) -> String {
        formatter("yyyy-MM-dd HH:mm:ss ZZZZZ").string(from: date)
    }

    /// Built per call: `DateFormatter` is not `Sendable`, and this is not a hot
    /// path (a handful of timestamps per export).
    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = format
        return formatter
    }
}
