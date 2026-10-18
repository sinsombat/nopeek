import Foundation
import Testing

import PWCore

/// Tests for `Exporter` (plan T20; spec §9 `Exporter`, acceptance 12: "เลือก
/// 7 วัน → ได้ md + csv (+ ndjson) ที่จำนวน events ตรงกับ log").
///
/// Every test works in throwaway directories under
/// `FileManager.temporaryDirectory` — both the log and the output — so the
/// suite can never read, overwrite or delete real evidence, and the default
/// output directory (`~/Library/Logs/NoPeek/exports`, ruling F4) is never
/// touched. Time enters through the exporter's injected `now`, so file names
/// and the report's timestamps are pinned instead of wall-clock.
///
/// The fixture timestamps are whole seconds: the models' ISO8601 encoding
/// keeps milliseconds only, and a whole second survives that exactly.
@Suite struct ExporterTests {

    // MARK: - Time helpers

    /// Fixed anchor date, mid-day, far from midnight and DST edges.
    private static let anchor = Date(timeIntervalSince1970: 1_762_000_000)

    /// A local date `offset` days from the anchor at `hour`:`minute`.
    private static func day(_ offset: Int, hour: Int = 12, minute: Int = 0) -> Date {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: anchor)
        let shifted = calendar.date(byAdding: .day, value: offset, to: start)!
        return calendar.date(byAdding: .minute, value: hour * 60 + minute, to: shifted)!
    }

    /// The window every pinned test exports: three days back through the end of
    /// today. Its edges hold no event, so nothing hangs on an inclusive bound
    /// by accident.
    private static let windowFrom = day(-3, hour: 0)
    private static let windowTo = day(0, hour: 23, minute: 59)

    // MARK: - Format oracles

    /// Test-local oracle for the file-name stamp `NoPeek-export-YYYYMMDD-HHMM`.
    private static func stamp(_ date: Date) -> String {
        formatter("yyyyMMdd-HHmm").string(from: date)
    }

    /// Test-local oracle for the report's human timestamp.
    private static func human(_ date: Date) -> String {
        formatter("yyyy-MM-dd HH:mm:ss ZZZZZ").string(from: date)
    }

    /// Test-local oracle for the CSV timestamp, which is the evidence log's own
    /// ISO8601 spelling.
    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = format
        return formatter
    }

    // MARK: - Files

    /// `events-YYYY-MM-DD.ndjson` by the event's local day (the T8 naming
    /// rule, reproduced here as an oracle).
    private static func dayFileName(for date: Date) -> String {
        "events-\(formatter("yyyy-MM-dd").string(from: date)).ndjson"
    }

    /// Appends `bytes` verbatim, as a crashed writer would.
    private static func append(raw bytes: String, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(bytes.utf8))
        try handle.close()
    }

    // MARK: - Fixtures

    private struct Fixture {
        let logDirectory: URL
        let outputDirectory: URL
        let log: EvidenceLog

        func cleanup() {
            try? FileManager.default.removeItem(at: logDirectory.deletingLastPathComponent())
        }
    }

    /// A fixture whose log directory does not exist yet — the exporter must not
    /// need one.
    private static func makeFixture() -> Fixture {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("nopeek-exporter-\(UUID().uuidString)")
        let logDirectory = base.appendingPathComponent("log")
        return Fixture(
            logDirectory: logDirectory,
            outputDirectory: base.appendingPathComponent("out"),
            log: EvidenceLog(directory: logDirectory)
        )
    }

    private static func classified(
        ts: Date,
        tier: Tier,
        actor: String,
        kind: EventKind = .screenCapture,
        reason: String = "default",
        path: String? = nil,
        pid: Int32? = nil,
        summary: String? = nil,
        source: EventSource = .logstream,
        count: Int = 1
    ) -> ClassifiedEvent {
        ClassifiedEvent(
            event: RawEvent(
                ts: ts,
                source: source,
                kind: kind,
                actor: actor,
                actorPath: path,
                pid: pid,
                rawSummary: summary
            ),
            tier: tier,
            reason: reason,
            count: count
        )
    }

    /// The dataset the pinned tests share: one event of every tier inside the
    /// window, plus one before it and one after, so filtering is checked in
    /// both directions.
    private struct Standard {
        let fixture: Fixture
        let before: ClassifiedEvent
        let org: ClassifiedEvent
        let remote: ClassifiedEvent
        let normal: ClassifiedEvent
        let noise: ClassifiedEvent
        let after: ClassifiedEvent

        var inRange: [ClassifiedEvent] { [org, remote, normal, noise] }
    }

    private static func standard() -> Standard {
        let fixture = makeFixture()
        let before = classified(ts: day(-8, hour: 10), tier: .normal, actor: "before-range")
        let org = classified(
            ts: day(-3, hour: 9),
            tier: .org,
            actor: "TaniumClient",
            reason: "orgPattern:Tanium",
            path: "/Library/ManageEngine/TaniumClient",
            pid: 4321,
            summary: "SCStream start request"
        )
        let remote = classified(
            ts: day(-2, hour: 10),
            tier: .remote,
            actor: "screensharingd",
            kind: .remoteControlSession,
            reason: "remote-control",
            source: .processwatch
        )
        let normal = classified(ts: day(-1, hour: 11), tier: .normal, actor: "screencaptureui", pid: 777)
        let noise = classified(
            ts: day(0, hour: 12),
            tier: .systemNoise,
            actor: "WindowManager",
            reason: "system-noise"
        )
        let after = classified(ts: day(3, hour: 13), tier: .normal, actor: "after-range")

        for event in [before, org, remote, normal, noise, after] {
            fixture.log.append(event)
        }
        return Standard(
            fixture: fixture,
            before: before,
            org: org,
            remote: remote,
            normal: normal,
            noise: noise,
            after: after
        )
    }

    /// The exporter under test, writing into the fixture's own output
    /// directory and stamping from a pinned clock.
    private static func exporter(_ fixture: Fixture, now: Date) -> Exporter {
        Exporter(
            log: fixture.log,
            outputDirectory: fixture.outputDirectory,
            now: { now }
        )
    }

    private static func markdown(of result: ExportResult) throws -> String {
        try String(contentsOf: result.markdownURL, encoding: .utf8)
    }

    /// One CSV row's fields, empty ones kept: a missing path or pid is an empty
    /// field, not a missing column.
    private static func csvFields(_ row: Substring) -> [String] {
        row.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    }

    // MARK: - The pinned tests

    @Test func testExportRangeFiltersAndCounts() throws {
        let standard = Self.standard()
        defer { standard.fixture.cleanup() }

        let result = try Self.exporter(standard.fixture, now: Self.day(0, hour: 14))
            .export(from: Self.windowFrom, to: Self.windowTo)

        // Four of the six fixture events are in the window.
        #expect(result.eventCount == 4)
        #expect(FileManager.default.fileExists(atPath: result.markdownURL.path))
        #expect(FileManager.default.fileExists(atPath: result.csvURL.path))
        #expect(FileManager.default.fileExists(atPath: result.ndjsonURL.path))

        let markdown = try Self.markdown(of: result)
        #expect(markdown.contains("- Events: 4"))
        #expect(markdown.contains("- By tier: ORG 1 · REMOTE 1 · NORMAL 1 · SYSTEM_NOISE 1 · ALLOWLIST 0"))

        let csv = try String(contentsOf: result.csvURL, encoding: .utf8)
        #expect(csv.split(separator: "\n").count == 5) // header + four rows

        // Events outside the window are in none of the artefacts.
        for artifact in [markdown, csv, try String(contentsOf: result.ndjsonURL, encoding: .utf8)] {
            #expect(!artifact.contains(standard.before.event.actor))
            #expect(!artifact.contains(standard.after.event.actor))
        }

        // The typed view and the raw copy cover exactly the same lines.
        #expect(try Data(contentsOf: result.ndjsonURL).split(separator: 0x0A).count == 4)
    }

    @Test func testMarkdownContainsOrgSection() throws {
        let standard = Self.standard()
        defer { standard.fixture.cleanup() }

        let result = try Self.exporter(standard.fixture, now: Self.day(0, hour: 14))
            .export(from: Self.windowFrom, to: Self.windowTo)
        let markdown = try Self.markdown(of: result)

        // The two pinned sections exist, in order, each carrying its count.
        let orgHeading = try #require(markdown.range(of: "## ORG events (1)"))
        let remoteHeading = try #require(markdown.range(of: "## REMOTE events (1)"))
        #expect(orgHeading.lowerBound < remoteHeading.lowerBound)

        // The ORG section names the org event in full: time, actor, kind, pid,
        // count, reason and path.
        let orgLine = "- \(Self.human(standard.org.event.ts)) — TaniumClient — screen-capture"
            + " — pid 4321 — count 1 — reason orgPattern:Tanium"
            + " — /Library/ManageEngine/TaniumClient — raw \"SCStream start request\""
        let orgLineRange = try #require(markdown.range(of: orgLine))
        #expect(orgLineRange.lowerBound > orgHeading.upperBound)
        #expect(orgLineRange.lowerBound < remoteHeading.lowerBound)

        // The REMOTE section names the remote event, with its own source.
        let remoteLine = "- \(Self.human(standard.remote.event.ts)) — screensharingd"
            + " — remote-control-session — count 1 — reason remote-control"
        #expect(markdown.contains(remoteLine))

        // The header states the data's source: this machine's own log.
        #expect(markdown.contains("this Mac's own evidence log"))
        #expect(markdown.contains(standard.fixture.logDirectory.path))

        // Non-org/remote tiers stay out of the sections (they are still in the
        // CSV and the raw copy).
        #expect(!markdown.contains(standard.normal.event.actor))
        #expect(!markdown.contains(standard.noise.event.actor))
    }

    @Test func testCsvHeaderAndRowCount() throws {
        let standard = Self.standard()
        defer { standard.fixture.cleanup() }

        let result = try Self.exporter(standard.fixture, now: Self.day(0, hour: 14))
            .export(from: Self.windowFrom, to: Self.windowTo)
        let csv = try String(contentsOf: result.csvURL, encoding: .utf8)
        let rows = csv.split(separator: "\n")

        // The pinned column order, one row per event line, trailing newline.
        #expect(rows.first == "ts,kind,actor,actorPath,pid,tier,reason,count,source")
        #expect(rows.count == 5)
        #expect(csv.hasSuffix("\n"))

        // Rows come back in read order (earliest day first, line order within a
        // file), so the org event leads. Every field is spelled as the log
        // spells it.
        #expect(Self.csvFields(rows[1]) == [
            Self.iso(standard.org.event.ts), "screen-capture", "TaniumClient",
            "/Library/ManageEngine/TaniumClient", "4321", "ORG",
            "orgPattern:Tanium", "1", "logstream",
        ])

        // A missing path or pid is an empty field — never "nil", never a dash.
        #expect(Self.csvFields(rows[2]) == [
            Self.iso(standard.remote.event.ts), "remote-control-session", "screensharingd",
            "", "", "REMOTE", "remote-control", "1", "processwatch",
        ])

        // The throttler's count survives as its own column.
        let counted = Self.classified(
            ts: Self.day(0, hour: 15),
            tier: .normal,
            actor: "burst",
            count: 7
        )
        standard.fixture.log.append(counted)
        let second = try Self.exporter(standard.fixture, now: Self.day(0, hour: 16))
            .export(from: Self.windowFrom, to: Self.day(0, hour: 23))
        let secondRows = try String(contentsOf: second.csvURL, encoding: .utf8)
            .split(separator: "\n")
        #expect(Self.csvFields(secondRows[5]) == [
            Self.iso(counted.event.ts), "screen-capture", "burst",
            "", "", "NORMAL", "default", "7", "logstream",
        ])
    }

    @Test func testExportWritesNdjsonCopy() throws {
        let fixture = Self.makeFixture()
        defer { fixture.cleanup() }

        // Two events in one day file; only the later one is in the window.
        let early = Self.classified(ts: Self.day(0, hour: 8), tier: .normal, actor: "early-line")
        let late = Self.classified(
            ts: Self.day(0, hour: 9),
            tier: .org,
            actor: "late-line",
            reason: "orgPattern:late",
            path: "/tmp/late-line",
            pid: 99
        )
        fixture.log.append(early)
        fixture.log.append(late)

        let dayFile = fixture.logDirectory.appendingPathComponent(Self.dayFileName(for: late.event.ts))
        try Self.append(raw: "not json at all\n{torn", to: dayFile)

        let result = try Self.exporter(fixture, now: Self.day(0, hour: 14))
            .export(from: late.event.ts, to: late.event.ts)

        #expect(result.eventCount == 1)

        // The copy is the log's own bytes for that one line: verbatim, not a
        // re-encoding, and without the foreign or torn lines.
        let original = try Data(contentsOf: dayFile)
        let lateLine = try #require(
            original.split(separator: 0x0A).first {
                String(decoding: $0, as: UTF8.self).contains("\"actor\":\"late-line\"")
            }
        )
        #expect(try Data(contentsOf: result.ndjsonURL) == Data(lateLine) + Data([0x0A]))

        // A whole-day window copies every real line of the file — byte for
        // byte, in file order — and still nothing from the two junk lines.
        let whole = try Self.exporter(fixture, now: Self.day(0, hour: 15))
            .export(from: Self.day(0, hour: 0), to: Self.day(0, hour: 23, minute: 59))
        #expect(whole.eventCount == 2)
        let foreignStart = try #require(original.range(of: Data("not json at all".utf8))?.lowerBound)
        #expect(try Data(contentsOf: whole.ndjsonURL) == original[..<foreignStart])
    }

    @Test func testFilenamesShareOneTimestamp() throws {
        let fixture = Self.makeFixture()
        defer { fixture.cleanup() }

        // `now` is read once and stamps all three names, so they always group.
        let now = Self.day(0, hour: 14, minute: 5)
        let result = try Self.exporter(fixture, now: now)
            .export(from: Self.day(-1), to: now)

        let stem = "NoPeek-export-\(Self.stamp(now))"
        #expect(result.markdownURL.lastPathComponent == "\(stem).md")
        #expect(result.csvURL.lastPathComponent == "\(stem).csv")
        #expect(result.ndjsonURL.lastPathComponent == "\(stem).ndjson")

        // All three live in the configured output directory, which the export
        // creates when it is not there yet.
        #expect(FileManager.default.fileExists(atPath: fixture.outputDirectory.path))
        for url in [result.markdownURL, result.csvURL, result.ndjsonURL] {
            #expect(url.deletingLastPathComponent().path == fixture.outputDirectory.path)
        }
    }

    @Test func testEmptyRangeExportsZeroCountSafely() throws {
        let fixture = Self.makeFixture()
        defer { fixture.cleanup() }

        // No log directory at all: the export still produces its three files.
        let now = Self.day(0, hour: 14)
        let result = try Self.exporter(fixture, now: now)
            .export(from: Self.day(-6), to: now)

        #expect(result.eventCount == 0)
        let markdown = try Self.markdown(of: result)
        #expect(markdown.contains("- Events: 0"))
        #expect(markdown.contains("- By tier: ORG 0 · REMOTE 0 · NORMAL 0 · SYSTEM_NOISE 0 · ALLOWLIST 0"))
        #expect(markdown.contains("## ORG events (0)"))
        #expect(markdown.contains("## REMOTE events (0)"))
        #expect(markdown.contains("_None in this range._"))

        #expect(try String(contentsOf: result.csvURL, encoding: .utf8)
            == "ts,kind,actor,actorPath,pid,tier,reason,count,source\n")
        #expect(try Data(contentsOf: result.ndjsonURL).isEmpty)

        // An inverted range reads as "nothing" — it neither throws nor exports
        // the whole log.
        let inverted = try Self.exporter(fixture, now: now)
            .export(from: Self.day(0), to: Self.day(-1))
        #expect(inverted.eventCount == 0)
        #expect(try Data(contentsOf: inverted.ndjsonURL).isEmpty)
    }

    // MARK: - CSV escaping

    @Test func testCsvQuotesFieldsWithCommasQuotesAndNewlines() throws {
        let fixture = Self.makeFixture()
        defer { fixture.cleanup() }

        // Reasons and paths come from log lines and process tables; a comma or
        // a quote in one must not shift the row's columns.
        let tricky = Self.classified(
            ts: Self.day(0, hour: 9),
            tier: .normal,
            actor: "weird, \"actor\"",
            reason: "why\nnot",
            path: "/tmp/with,comma"
        )
        fixture.log.append(tricky)

        let result = try Self.exporter(fixture, now: Self.day(0, hour: 14))
            .export(from: Self.day(0, hour: 0), to: Self.day(0, hour: 23, minute: 59))

        let csv = try String(contentsOf: result.csvURL, encoding: .utf8)
        #expect(csv.contains("\"weird, \"\"actor\"\"\""))
        #expect(csv.contains("\"/tmp/with,comma\""))
        #expect(csv.contains("\"why\nnot\""))
    }

    // MARK: - Live smoke test

    @Test func testSmokeExportsThisMachinesLog() throws {
        // The one test that reads the real evidence log
        // (`~/Library/Logs/NoPeek`, the app's own non-TCC directory) and
        // prints the report the human's acceptance run compares against the
        // menu's export. It writes to a throwaway directory, never to the
        // default exports folder, and holds only invariants that cannot flake
        // on a fresh machine (no log at all → zero events).
        let fixture = Self.makeFixture()
        defer { fixture.cleanup() }

        let logDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/NoPeek")
        let log = EvidenceLog(directory: logDirectory)
        let now = Date()
        let from = Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: now))!

        let exporter = Exporter(log: log, outputDirectory: fixture.outputDirectory, now: { now })
        let result = try exporter.export(from: from, to: now)

        let markdown = try Self.markdown(of: result)
        let csv = try String(contentsOf: result.csvURL, encoding: .utf8)
        let copy = try Data(contentsOf: result.ndjsonURL)

        // Internal consistency of the three artefacts, then the raw copy
        // against the typed read. The app is running and appending while this
        // exports, so the copy — the second read — may be one line ahead (see
        // the exporter's note); it must never be behind.
        #expect(csv.split(separator: "\n").count == result.eventCount + 1)
        #expect(markdown.contains("- Events: \(result.eventCount)"))
        let copyLines = copy.isEmpty ? 0 : copy.split(separator: 0x0A).count
        let readNow = log.read(from: from, to: now).count
        #expect(copyLines >= result.eventCount)
        #expect(copyLines - result.eventCount <= 1)
        #expect(readNow == result.eventCount || readNow == copyLines)

        print("""
        NoPeek export smoke — \(Self.human(now))
        log directory: \(logDirectory.path)
        six-day range: \(Self.human(from)) … \(Self.human(now))
        events: \(result.eventCount) · csv rows: \(csv.split(separator: "\n").count - 1)
        raw copy lines: \(copyLines) · re-read now: \(readNow)
        --- report head ---
        \(markdown.split(separator: "\n").prefix(8).joined(separator: "\n"))
        """)
    }
}
