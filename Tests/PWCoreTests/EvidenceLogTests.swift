import Foundation
import Testing

import PWCore

/// Tests for `EvidenceLog` (spec §8, plan T8).
///
/// Every test works in a throwaway directory under
/// `FileManager.temporaryDirectory` — never `~/Library/Logs` — so the suite
/// can neither read nor delete real evidence, and no TCC-sensitive path is
/// touched.
///
/// Time enters through the two doors the interface pins: `append(_:)` files an
/// event by the **event's own** local day, while `appendRaw` and
/// `purgeOldFiles` read the injected `now`. Tests therefore never sleep and
/// never depend on the wall clock: the "today" of a retention run is whatever
/// the test's `TestClock` says.
///
/// The suite runs wherever the machine's timezone is: expected file names come
/// from a test-local `yyyy-MM-dd` formatter over `TimeZone.current` (the same
/// rule the implementation uses) instead of hard-coded date strings, so
/// nothing here assumes UTC or +07:00. Every written timestamp is whole-second
/// or an exactly representable fraction of one, because the models' ISO8601
/// encoding keeps milliseconds only (T1 sharp edge).
@Suite struct EvidenceLogTests {

    // MARK: - Helpers

    /// Hand-driven clock for the paths that read `now` (lifecycle events,
    /// retention); `append(_:)` ignores it and uses the event's timestamp.
    private final class TestClock {
        var now: Date

        init(now: Date) {
            self.now = now
        }

        func advance(days: Int) {
            now = Calendar.current.date(byAdding: .day, value: days, to: now)!
        }
    }

    /// Fixed anchor date, mid-day. Its value is irrelevant to the assertions —
    /// every test states its days relative to this anchor — but mid-day keeps
    /// the day arithmetic below far from midnight and DST edges.
    private static let anchor = Date(timeIntervalSince1970: 1_762_000_000)

    /// A whole-second local date `offset` days from the anchor at `hour`.
    private static func day(_ offset: Int, hour: Int = 12) -> Date {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: anchor)
        let shifted = calendar.date(byAdding: .day, value: offset, to: start)!
        return calendar.date(byAdding: .hour, value: hour, to: shifted)!
    }

    /// Test-local oracle for the on-disk naming rule:
    /// `events-YYYY-MM-DD.ndjson` by the event's day in the machine's local
    /// timezone.
    private static func fileName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return "events-\(formatter.string(from: date)).ndjson"
    }

    private static func scratchDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("nopeek-evidence-log-\(UUID().uuidString)")
    }

    private static func cleanup(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Contents of `directory` as a sorted name list.
    private static func names(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    /// One classified ORG event with every schema field populated, so a
    /// round-trip through the log exercises the whole flat encoding (spec §8).
    private static func classified(ts: Date, actor: String = "TaniumClient") -> ClassifiedEvent {
        ClassifiedEvent(
            event: RawEvent(
                ts: ts,
                source: .logstream,
                kind: .screenCapture,
                actor: actor,
                actorPath: "/Library/ManageEngine/\(actor)",
                pid: 4321,
                rawSummary: "SCStream start request"
            ),
            tier: .org,
            reason: "orgPattern:Tanium",
            count: 1
        )
    }

    /// Appends `bytes` verbatim to `file`, as a crashed writer would.
    private static func append(raw bytes: String, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(bytes.utf8))
        try handle.close()
    }

    // MARK: - Append / naming

    @Test func testAppendWritesLineAndReadsBack() throws {
        let directory = Self.scratchDirectory()
        defer { Self.cleanup(directory) }

        // The directory does not exist yet: `append` must create it.
        #expect(!FileManager.default.fileExists(atPath: directory.path))

        let log = EvidenceLog(directory: directory)
        #expect(log.retentionDays == 30) // pinned default (spec §7: 30 days)

        let ts = Self.day(0, hour: 9).addingTimeInterval(0.125)
        let event = Self.classified(ts: ts)
        log.append(event)

        let file = directory.appendingPathComponent(Self.fileName(for: ts))
        let contents = try String(contentsOf: file, encoding: .utf8)

        // One flat JSON object and exactly one trailing newline: the ndjson
        // contract (spec §8).
        #expect(contents.hasSuffix("\n"))
        #expect(contents.filter { $0 == "\n" }.count == 1)
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(contents.utf8)) as? [String: Any]
        )
        #expect(object["event"] == nil) // flat, not nested
        #expect(object["kind"] as? String == "screen-capture")
        #expect(object["actor"] as? String == "TaniumClient")
        #expect(object["pid"] as? Int == 4321)
        #expect(object["tier"] as? String == "ORG")

        // The same event comes back out of `read` (inclusive bounds).
        #expect(log.read(from: ts, to: ts) == [event])
    }

    @Test func testFilenameByDay() throws {
        let directory = Self.scratchDirectory()
        defer { Self.cleanup(directory) }

        // The injected `now` is deliberately on another day: the file name is
        // chosen by the *event's* day, not by when the write happened.
        let clock = TestClock(now: Self.day(5))
        let log = EvidenceLog(directory: directory, now: { clock.now })

        let first = Self.classified(ts: Self.day(0, hour: 10))
        let second = Self.classified(ts: Self.day(1, hour: 10))
        log.append(first)
        log.append(second)

        #expect(try Self.names(in: directory) == [
            Self.fileName(for: first.event.ts),
            Self.fileName(for: second.event.ts),
        ].sorted())

        // Each file holds exactly its own day's event.
        #expect(log.read(from: first.event.ts, to: first.event.ts) == [first])
        #expect(log.read(from: second.event.ts, to: second.event.ts) == [second])
    }

    // MARK: - lastActivity

    @Test func testLastActivityFromLastLine() throws {
        let directory = Self.scratchDirectory()
        defer { Self.cleanup(directory) }

        let log = EvidenceLog(directory: directory)
        let older = Self.classified(ts: Self.day(0, hour: 23))
        let first = Self.classified(ts: Self.day(1, hour: 8))
        let last = Self.classified(ts: Self.day(1, hour: 9).addingTimeInterval(0.5))
        log.append(older)
        log.append(first)
        log.append(last)

        // The newest file is day 1; its last line is what counts — not the
        // earlier line in that file, and not the older day-0 file.
        #expect(log.lastActivity() == last.event.ts)
    }

    @Test func testLastActivityUsesNewestDayNotNewestMtime() throws {
        // Rotation is by the day in the name: a restore or backup that touches
        // an older file must not make it win.
        let directory = Self.scratchDirectory()
        defer { Self.cleanup(directory) }

        let log = EvidenceLog(directory: directory)
        let old = Self.classified(ts: Self.day(0, hour: 9))
        let new = Self.classified(ts: Self.day(1, hour: 9))
        log.append(old)
        log.append(new)

        let oldFile = directory.appendingPathComponent(Self.fileName(for: old.event.ts))
        try FileManager.default.setAttributes(
            [.modificationDate: Self.day(100)],
            ofItemAtPath: oldFile.path
        )

        #expect(log.lastActivity() == new.event.ts)
    }

    @Test func testLastActivityEmptyDirNil() throws {
        let directory = Self.scratchDirectory()
        defer { Self.cleanup(directory) }

        let log = EvidenceLog(directory: directory)
        #expect(log.lastActivity() == nil) // directory does not exist yet

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #expect(log.lastActivity() == nil) // directory exists but is empty
        #expect(log.read(from: Self.day(-30), to: Self.day(0)).isEmpty)
    }

    @Test func testLastActivityFallsBackToMtimeOnGarbageTail() throws {
        // A crash mid-append can leave a torn last line. The previous readable
        // line would report an activity older than reality, so the file's
        // modification date is the pinned fallback.
        let directory = Self.scratchDirectory()
        defer { Self.cleanup(directory) }

        let log = EvidenceLog(directory: directory)
        let good = Self.classified(ts: Self.day(0, hour: 9))
        log.append(good)

        // Torn write: bytes with no closing brace and no newline.
        let file = directory.appendingPathComponent(Self.fileName(for: good.event.ts))
        try Self.append(raw: "{\"ts\":\"2026-1", to: file)

        let mtime = Self.day(0, hour: 15)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: file.path)

        let activity = try #require(log.lastActivity())
        #expect(activity != good.event.ts)
        #expect(abs(activity.timeIntervalSince(mtime)) < 1) // mtime (fs rounding tolerance)
    }

    // MARK: - Retention

    @Test func testPurgeRemovesOlderThanRetention() throws {
        let directory = Self.scratchDirectory()
        defer { Self.cleanup(directory) }

        // retentionDays = 3 keeps today and the two days before it; the day
        // exactly on the retention edge (-3) is gone, as are older ones.
        let clock = TestClock(now: Self.day(0, hour: 23))
        let log = EvidenceLog(directory: directory, retentionDays: 3, now: { clock.now })

        for offset in [-5, -3, -2, -1, 0] {
            log.append(Self.classified(ts: Self.day(offset, hour: 10)))
        }
        #expect(try Self.names(in: directory).count == 5)

        log.purgeOldFiles()

        #expect(try Self.names(in: directory) == [-2, -1, 0]
            .map { Self.fileName(for: Self.day($0, hour: 10)) }
            .sorted())
    }

    @Test func testPurgeFallsBackToMtimeForUnparsableName() throws {
        // A file whose name does not parse is aged by its modification date,
        // and anything outside the naming scheme (here: `.DS_Store`) is never
        // touched at all.
        let directory = Self.scratchDirectory()
        defer { Self.cleanup(directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let clock = TestClock(now: Self.day(0, hour: 12))
        let log = EvidenceLog(directory: directory, retentionDays: 2, now: { clock.now })

        let files = [
            ("events-not-a-day.ndjson", Self.day(-10)),
            ("events-also-bad.ndjson", Self.day(0)),
            (".DS_Store", Self.day(-10)),
        ]
        for (name, mtime) in files {
            let url = directory.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: Data())
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        }

        log.purgeOldFiles()

        #expect(try Self.names(in: directory) == [".DS_Store", "events-also-bad.ndjson"])
    }

    // MARK: - Range read

    @Test func testReadRangeFilters() throws {
        let directory = Self.scratchDirectory()
        defer { Self.cleanup(directory) }

        let log = EvidenceLog(directory: directory)
        let before = Self.classified(ts: Self.day(0, hour: 9), actor: "before")
        let from = Self.classified(ts: Self.day(1, hour: 10), actor: "from")
        let middle = Self.classified(ts: Self.day(1, hour: 11), actor: "middle")
        let to = Self.classified(ts: Self.day(2, hour: 12), actor: "to")
        let after = Self.classified(ts: Self.day(2, hour: 13), actor: "after")
        for event in [before, from, middle, to, after] {
            log.append(event)
        }

        // Bounds are inclusive: the `from` and `to` events themselves are in.
        // Result order is file order, then line order within the file.
        #expect(log.read(from: from.event.ts, to: to.event.ts) == [from, middle, to])

        // A single instant still reads the event landing exactly on it.
        #expect(log.read(from: middle.event.ts, to: middle.event.ts) == [middle])

        // An inverted range cannot match anything.
        #expect(log.read(from: to.event.ts, to: from.event.ts).isEmpty)
    }

    @Test func testReadSkipsMalformedLines() throws {
        // Torn or foreign lines in a day file are skipped one by one; they
        // must not fail the whole read (spec §4: the log is read while it is
        // being written).
        let directory = Self.scratchDirectory()
        defer { Self.cleanup(directory) }

        let log = EvidenceLog(directory: directory)
        let first = Self.classified(ts: Self.day(0, hour: 8))
        let second = Self.classified(ts: Self.day(0, hour: 9))
        log.append(first)
        log.append(second)

        let file = directory.appendingPathComponent(Self.fileName(for: first.event.ts))
        try Self.append(raw: "not json at all\n", to: file) // complete foreign line
        try Self.append(raw: "{torn", to: file) // torn line, no newline

        #expect(log.read(from: Self.day(0, hour: 0), to: Self.day(0, hour: 23)) == [first, second])
    }

    // MARK: - Lifecycle helper

    @Test func testAppendRawLifecycleEvent() throws {
        let directory = Self.scratchDirectory()
        defer { Self.cleanup(directory) }

        let startedAt = Self.day(0, hour: 14).addingTimeInterval(0.125)
        let clock = TestClock(now: startedAt)
        let log = EvidenceLog(directory: directory, now: { clock.now })

        log.appendRaw(kind: .monitorStarted)

        let events = log.read(from: Self.day(0, hour: 0), to: Self.day(0, hour: 23))
        let event = try #require(events.first)
        #expect(events.count == 1)
        #expect(event.event.ts == startedAt) // ts = injected now
        #expect(event.event.source == .system)
        #expect(event.event.kind == .monitorStarted)
        #expect(event.event.actor == "nopeek") // default actor
        #expect(event.tier == .systemNoise) // logged, never notified via the pipeline
        #expect(event.reason == "lifecycle")
        #expect(event.count == 1)

        // The write lands in the file for the injected clock's day.
        #expect(try Self.names(in: directory) == [Self.fileName(for: startedAt)])

        // An explicit actor is honoured.
        clock.advance(days: 1)
        log.appendRaw(kind: .heartbeat, actor: "watchdog")
        let later = log.read(from: Self.day(1, hour: 0), to: Self.day(1, hour: 23))
        #expect(later.map(\.event.actor) == ["watchdog"])
        #expect(later.map(\.event.kind) == [.heartbeat])
    }
}
