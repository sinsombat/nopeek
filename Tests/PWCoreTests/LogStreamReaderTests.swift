import Foundation
import Testing

import PWCore

/// Tests for `LogStreamReader` (spec §3 auto-restart, §4 log-stream watcher).
///
/// The reader is exercised against throwaway `/bin/sh` scripts instead of the
/// real `/usr/bin/log stream`, so the child's entire lifecycle (clean exit,
/// immediate death, stubborn child, spawn failure) is under test control.
/// Callbacks fire on the reader's internal serial queue, not on the test's
/// thread, so observations are collected in `LockedRecorder`.
///
/// `testDefaultPredicateMatchesFile` is the cross-language guard for the
/// predicate: `LogStreamReader.defaultPredicate` must equal the content of
/// `scripts/log-predicate.txt`, which `scripts/capture-probe.sh` feeds to the
/// same `log stream` invocation (Ruling: the file is the single source of
/// truth; the string is deliberately not duplicated here).
@Suite struct LogStreamReaderTests {

    // MARK: - Helpers

    /// One callback observation, in the order the reader produced it.
    enum Event: Equatable {
        case line(String)
        case state(LogStreamReader.State)
    }

    /// Thread-safe event recorder for the reader's callbacks.
    final class LockedRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Event] = []

        func record(_ event: Event) {
            lock.lock()
            defer { lock.unlock() }
            storage.append(event)
        }

        var events: [Event] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    /// Per-test scratch directory holding the fake child script and its
    /// marker / pid files.
    struct Scratch {
        let directory: URL

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("nopeek-log-stream-reader-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        func path(_ name: String) -> String {
            directory.appendingPathComponent(name).path
        }

        func url(_ name: String) -> URL {
            directory.appendingPathComponent(name)
        }

        /// Writes `body` as the fake child script and returns the reader
        /// command that runs it. Going through `/bin/sh` keeps the test
        /// independent of shebang handling and file permissions.
        func command(script body: String) throws -> [String] {
            let scriptURL = url("fake-stream.sh")
            try body.write(to: scriptURL, atomically: true, encoding: .utf8)
            return ["/bin/sh", scriptURL.path]
        }
    }

    /// Polls `condition` until it is true or `timeout` elapses. Returns the
    /// last value, so a failed `#expect` shows the condition never held.
    static func wait(
        upTo timeout: Duration = .seconds(5),
        for condition: @Sendable () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    static func isDegraded(_ event: Event?) -> Bool {
        guard case .state(.degraded) = event else { return false }
        return true
    }

    /// The `retryIn` values of every `.degraded` state, in order.
    static func degradedDelays(_ events: [Event]) -> [TimeInterval] {
        events.compactMap {
            guard case .state(.degraded(let retryIn)) = $0 else { return nil }
            return retryIn
        }
    }

    /// Non-empty line count of a file the fake child appends to (0 while the
    /// file does not exist yet).
    static func countLines(at path: String) -> Int {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return 0 }
        return text.split(separator: "\n", omittingEmptySubsequences: true).count
    }

    /// PID the fake child recorded for itself, once it has done so.
    static func readPID(from path: String) -> pid_t? {
        guard
            let text = try? String(contentsOfFile: path, encoding: .utf8),
            let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return pid
    }

    // MARK: - Predicate single source

    @Test func testDefaultPredicateMatchesFile() throws {
        // The canonical predicate text lives in scripts/log-predicate.txt.
        // Resolve the repo root relative to this file:
        // <root>/Tests/PWCoreTests/LogStreamReaderTests.swift → three levels up.
        let fileURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/log-predicate.txt")

        guard let fileContents = try? String(contentsOf: fileURL, encoding: .utf8) else {
            try Test.cancel("cannot read \(fileURL.path) — skipping the predicate cross-check")
        }

        // capture-probe.sh reads the file with `$(cat …)`, which strips the
        // trailing newline; that stripped text is the predicate proper.
        let canonical = fileContents.trimmingCharacters(in: .newlines)
        #expect(!canonical.isEmpty, "scripts/log-predicate.txt is empty")
        #expect(
            LogStreamReader.defaultPredicate == canonical,
            "defaultPredicate drifted from scripts/log-predicate.txt"
        )
    }

    // MARK: - Reading

    @Test func testReadsLinesUntilExit() async throws {
        let scratch = try Scratch()
        defer { try? FileManager.default.removeItem(at: scratch.directory) }
        let command = try scratch.command(script: """
        printf 'one\\ntwo\\nthree\\n'
        exit 0
        """)

        let recorder = LockedRecorder()
        let reader = LogStreamReader(
            command: command,
            backoff: [30],
            onLine: { recorder.record(.line(String(decoding: $0, as: UTF8.self))) },
            onState: { recorder.record(.state($0)) }
        )
        defer { reader.stop() }

        reader.start()

        let sawDegraded = await Self.wait { Self.isDegraded(recorder.events.last) }
        #expect(sawDegraded, "no .degraded after the child exited")
        // A dead child is the normal path: all three lines, in order, then
        // exactly one degraded state (`backoff[0]` is the first retry step).
        #expect(recorder.events == [
            .state(.running),
            .line("one"),
            .line("two"),
            .line("three"),
            .state(.degraded(retryIn: 30)),
        ])
    }

    @Test func testMalformedDoesNotKillStream() async throws {
        let scratch = try Scratch()
        defer { try? FileManager.default.removeItem(at: scratch.directory) }
        // Garbage and valid lines interleaved, then the child stays alive:
        // the reader is a byte pump, so malformed lines are delivered verbatim
        // (`LogLineParser` decides what they are worth) and no state change
        // happens while the stream is up.
        let command = try scratch.command(script: """
        printf 'garbage one\\n{"eventMessage": "valid one"}\\n<not json>\\n{"process": "replayd"}\\n{truncated\\n'
        exec sleep 30
        """)

        let recorder = LockedRecorder()
        let reader = LogStreamReader(
            command: command,
            backoff: [0.1],
            onLine: { recorder.record(.line(String(decoding: $0, as: UTF8.self))) },
            onState: { recorder.record(.state($0)) }
        )
        defer { reader.stop() }

        reader.start()

        let sawAllLines = await Self.wait { recorder.events.count == 6 }
        #expect(sawAllLines, "expected 5 lines + 1 running state, got \(recorder.events)")
        // Give a premature child death a chance to show up as .degraded.
        try await Task.sleep(for: .milliseconds(200))
        #expect(recorder.events == [
            .state(.running),
            .line("garbage one"),
            .line(#"{"eventMessage": "valid one"}"#),
            .line("<not json>"),
            .line(#"{"process": "replayd"}"#),
            .line("{truncated"),
        ])
    }

    @Test func testFinalLineWithoutNewlineIsFlushed() async throws {
        let scratch = try Scratch()
        defer { try? FileManager.default.removeItem(at: scratch.directory) }
        // A child that dies mid-line must not lose the bytes it did write.
        let command = try scratch.command(script: """
        printf 'complete\\npartial'
        exit 0
        """)

        let recorder = LockedRecorder()
        let reader = LogStreamReader(
            command: command,
            backoff: [30],
            onLine: { recorder.record(.line(String(decoding: $0, as: UTF8.self))) },
            onState: { recorder.record(.state($0)) }
        )
        defer { reader.stop() }

        reader.start()

        let sawDegraded = await Self.wait { Self.isDegraded(recorder.events.last) }
        #expect(sawDegraded, "no .degraded after the child exited")
        #expect(recorder.events == [
            .state(.running),
            .line("complete"),
            .line("partial"),
            .state(.degraded(retryIn: 30)),
        ])
    }

    // MARK: - Restart + backoff

    @Test func testRestartsWithBackoff() async throws {
        let scratch = try Scratch()
        defer { try? FileManager.default.removeItem(at: scratch.directory) }
        let runsFile = scratch.path("runs")
        // Dies immediately, every run; the marker file counts the runs.
        let command = try scratch.command(script: """
        echo run >> "\(runsFile)"
        exit 1
        """)

        let recorder = LockedRecorder()
        let reader = LogStreamReader(
            command: command,
            backoff: [0.1, 0.1],
            onLine: { _ in },
            onState: { recorder.record(.state($0)) }
        )
        defer { reader.stop() }

        reader.start()

        let restarted = await Self.wait { Self.countLines(at: runsFile) >= 2 }
        #expect(restarted, "the child never ran a second time")
        let sawSequence = await Self.wait { recorder.events.count >= 3 }
        #expect(sawSequence, "expected running → degraded → running, got \(recorder.events)")
        #expect(Array(recorder.events.prefix(3)) == [
            .state(.running),
            .state(.degraded(retryIn: 0.1)),
            .state(.running),
        ])
    }

    @Test func testStableRunResetsBackoff() async throws {
        let scratch = try Scratch()
        defer { try? FileManager.default.removeItem(at: scratch.directory) }
        let runsFile = scratch.path("runs")
        // Runs 1–2 die immediately, advancing the backoff; run 3 lasts longer
        // than the reset interval, so its death must retry at backoff[0].
        let command = try scratch.command(script: """
        echo run >> "\(runsFile)"
        if [ "$(wc -l < "\(runsFile)" | tr -d ' ')" -le 2 ]; then exit 1; fi
        sleep 0.45
        exit 1
        """)

        let recorder = LockedRecorder()
        let reader = LogStreamReader(
            command: command,
            backoff: [0.15, 0.5, 0.9],
            stableResetInterval: 0.3,
            onLine: { _ in },
            onState: { recorder.record(.state($0)) }
        )
        defer { reader.stop() }

        reader.start()

        let sawThreeDegrades = await Self.wait { Self.degradedDelays(recorder.events).count >= 3 }
        #expect(sawThreeDegrades, "expected three degrade cycles, got \(recorder.events)")
        // 0.15 = first failure, 0.5 = second failure has stepped up; the
        // stable run then resets to 0.15 instead of stepping up to 0.9.
        #expect(Array(Self.degradedDelays(recorder.events).prefix(3)) == [0.15, 0.5, 0.15])
    }

    @Test func testSpawnFailureIsDegradedNotCrash() async throws {
        let recorder = LockedRecorder()
        let reader = LogStreamReader(
            command: ["/nonexistent/nopeek-fake-log-stream"],
            backoff: [0.1, 0.1],
            onLine: { _ in },
            onState: { recorder.record(.state($0)) }
        )
        defer { reader.stop() }

        reader.start()

        let sawDegraded = await Self.wait { Self.isDegraded(recorder.events.first) }
        #expect(sawDegraded, "a command that cannot launch must still degrade")
        #expect(recorder.events.first == .state(.degraded(retryIn: 0.1)))
        #expect(!recorder.events.contains(.state(.running)))
    }

    // MARK: - Stopping

    @Test func testStopTerminatesChild() async throws {
        let scratch = try Scratch()
        defer { try? FileManager.default.removeItem(at: scratch.directory) }
        let pidFile = scratch.path("child.pid")
        let command = try scratch.command(script: """
        echo $$ > "\(pidFile)"
        exec sleep 30
        """)

        let recorder = LockedRecorder()
        let reader = LogStreamReader(
            command: command,
            backoff: [0.1],
            onLine: { _ in },
            onState: { recorder.record(.state($0)) }
        )
        defer { reader.stop() }

        reader.start()

        let started = await Self.wait { Self.readPID(from: pidFile) != nil }
        #expect(started, "the child never recorded its pid")
        #expect(recorder.events == [.state(.running)])
        let pid = try #require(Self.readPID(from: pidFile))
        #expect(kill(pid, 0) == 0, "child \(pid) is not alive before stop()")

        reader.stop()

        let died = await Self.wait { kill(pid, 0) != 0 }
        #expect(died, "child \(pid) survived stop()")
        // stop() must suppress the degraded state that the death would cause.
        try await Task.sleep(for: .milliseconds(300))
        #expect(recorder.events == [.state(.running)])
    }

    @Test func testStopEscalatesToSigkill() async throws {
        let scratch = try Scratch()
        defer { try? FileManager.default.removeItem(at: scratch.directory) }
        let pidFile = scratch.path("child.pid")
        // The child ignores SIGTERM (the disposition survives exec), so only
        // the SIGKILL escalation can end it.
        let command = try scratch.command(script: """
        echo $$ > "\(pidFile)"
        trap '' TERM
        exec sleep 30
        """)

        let recorder = LockedRecorder()
        let reader = LogStreamReader(
            command: command,
            backoff: [0.1],
            sigkillGracePeriod: 0.2,
            onLine: { _ in },
            onState: { recorder.record(.state($0)) }
        )
        defer { reader.stop() }

        reader.start()

        let started = await Self.wait { Self.readPID(from: pidFile) != nil }
        #expect(started, "the child never recorded its pid")
        let pid = try #require(Self.readPID(from: pidFile))

        reader.stop()

        let died = await Self.wait { kill(pid, 0) != 0 }
        #expect(died, "child \(pid) survived SIGTERM + SIGKILL escalation")
        try await Task.sleep(for: .milliseconds(200))
        #expect(recorder.events == [.state(.running)])
    }
}
