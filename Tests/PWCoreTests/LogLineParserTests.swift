import Foundation
import Testing

import PWCore

/// Tests for `LogLineParser` (spec §4 log-stream watcher) against a curated
/// slice of a real `log stream --style ndjson` capture taken on 2026-10-18
/// while opening/closing the ⌘⇧5 screenshot toolbar and invoking Mission
/// Control 2–3 times.
///
/// `Tests/PWCoreTests/Fixtures/probe-2026-10-18.ndjson` is the curated subset
/// (the raw 2181-line / 2.2 MB probe stays out of the repo). Its last three
/// lines are hand-edited cases: a redacted `processImagePath` kept matchable
/// through a synthetic `process` key, a redacted path matched through the
/// `com.apple.ScreenCaptureKit` subsystem, and a JSON line truncated
/// mid-object. The non-JSON preamble line is an inline string (it is text, not
/// ndjson).
///
/// The tests pin the two halves of spec §5's precision requirement: real
/// capture truth signals (`replayd`'s `updateScreenCaptureDidStart` and the
/// ScreenCaptureKit construction calls) must parse, while Mission Control /
/// XPC chatter must return `nil` so it never reaches the Classifier as a
/// candidate.
@Suite struct LogLineParserTests {

    // MARK: - Helpers

    /// Parser under test: the shipped default rules, nothing added.
    private static let parser = LogLineParser(rules: KindRule.screenCaptureDefaults)

    private static func fixtureLines() throws -> [String] {
        let url = try #require(
            Bundle.module.url(
                forResource: "probe-2026-10-18",
                withExtension: "ndjson",
                subdirectory: "Fixtures"
            ),
            "fixture Fixtures/probe-2026-10-18.ndjson missing from the test bundle"
        )
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    private static func fixtureLine(containing needles: [String]) throws -> String {
        try #require(
            fixtureLines().first { line in needles.allSatisfy { line.contains($0) } },
            "no fixture line contains all of \(needles)"
        )
    }

    /// Builds a line shaped like `log stream --style ndjson` output, with only
    /// the keys the test cares about.
    private static func syntheticLine(
        process: String? = nil,
        processImagePath: String? = nil,
        subsystem: String? = nil,
        eventMessage: String? = nil,
        timestamp: String? = "2026-10-18 10:30:56.186783+0700",
        processID: Int? = nil
    ) throws -> String {
        var object: [String: Any] = [:]
        if let process { object["process"] = process }
        if let processImagePath { object["processImagePath"] = processImagePath }
        if let subsystem { object["subsystem"] = subsystem }
        if let eventMessage { object["eventMessage"] = eventMessage }
        if let timestamp { object["timestamp"] = timestamp }
        if let processID { object["processID"] = processID }
        let data = try JSONSerialization.data(withJSONObject: object)
        return try #require(String(data: data, encoding: .utf8))
    }

    /// The millisecond value the fixture's `2026-10-18 10:30:56.186783+0700`
    /// corresponds to, built without reusing the parser's own date code.
    private static func expectedReportedTimestamp() throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try #require(formatter.date(from: "2026-10-18T03:30:56.186Z"))
    }

    // MARK: - Real capture lines

    @Test func testParsesScreenCaptureLine() throws {
        // replayd is the process that owns the on-screen capture indicator;
        // `updateScreenCaptureDidStart` is the truth signal that a capture began.
        let line = try Self.fixtureLine(
            containing: ["updateScreenCaptureDidStart", "client has entitlement to suppress screen indicator"]
        )
        let event = try #require(Self.parser.parse(line: line))

        #expect(event.kind == .screenCapture)
        #expect(event.source == .logstream)
        #expect(event.actor == "replayd")
        #expect(event.actorPath == "/usr/libexec/replayd")
        #expect(event.pid == 97030)

        let summary = try #require(event.rawSummary)
        #expect(summary.contains("updateScreenCaptureDidStart"))
        #expect(summary.contains("suppress screen indicator"))
        #expect(summary.count <= 200)
    }

    @Test func testTimestampParsesLogStreamFormat() throws {
        // log stream ndjson timestamps look like
        // "2026-10-18 10:30:56.186783+0700" — space separator, 6-digit
        // fraction, RFC-822 offset (see LogLineParserTests docs).
        let line = try Self.fixtureLine(
            containing: ["updateScreenCaptureDidStart", "client has entitlement to suppress screen indicator"]
        )
        let event = try #require(Self.parser.parse(line: line))

        let expected = try Self.expectedReportedTimestamp()
        // The parser keeps microseconds; ISO8601 formatting here only carries
        // milliseconds, so allow the sub-millisecond remainder.
        #expect(abs(event.ts.timeIntervalSince(expected)) <= 0.002)
    }

    @Test func testParsesAllCapturedCaptureStartLines() throws {
        // The probe contains 11 real replayd updateScreenCaptureDidStart lines
        // (plus one hand-edited redacted copy covered by its own test).
        let lines = try Self.fixtureLines().filter {
            $0.contains("updateScreenCaptureDidStart") && !$0.contains("<private>")
        }
        #expect(lines.count == 11)

        for line in lines {
            let event = try #require(Self.parser.parse(line: line), "line did not parse: \(line.prefix(120))")
            #expect(event.kind == .screenCapture)
            #expect(event.actor == "replayd")
        }
    }

    @Test func testParsesScreenCaptureKitConstructionLines() throws {
        // A third-party capturer logs the ScreenCaptureKit construction calls
        // under its own processImagePath; screencapture does the same here.
        for needle in [
            "SCDisplay initWithDict",
            "SCShareableContent getDisplayForDisplayId",
            "SCContentFilter initWithDisplay",
        ] {
            let line = try Self.fixtureLine(containing: [needle])
            let event = try #require(Self.parser.parse(line: line), "no event for \(needle)")
            #expect(event.kind == .screenCapture, "wrong kind for \(needle)")
            #expect(event.actor == "screencapture", "wrong actor for \(needle)")
            #expect(event.actorPath == "/usr/sbin/screencapture", "wrong path for \(needle)")
        }
    }

    @Test func testScreenCaptureKitSubsystemMatchesAnyProcess() throws {
        // Any process logging under the ScreenCaptureKit subsystem is a
        // capture participant, even when the process is unknown to the rules.
        let line = try Self.syntheticLine(
            processImagePath: "/Applications/OtherRecorder.app/Contents/MacOS/OtherRecorder",
            subsystem: "com.apple.ScreenCaptureKit",
            eventMessage: "-[SCStream startCaptureWithCompletionHandler:]"
        )
        let event = try #require(Self.parser.parse(line: line))

        #expect(event.kind == .screenCapture)
        #expect(event.actor == "OtherRecorder")
        #expect(event.actorPath == "/Applications/OtherRecorder.app/Contents/MacOS/OtherRecorder")
    }

    @Test func testApprovalAndRemoteControlRules() throws {
        let approval = try Self.syntheticLine(
            processImagePath: "/System/Library/CoreServices/ScreenCaptureApprovalUI.app/Contents/MacOS/ScreenCaptureApprovalUI",
            eventMessage: "Presenting capture approval"
        )
        let approvalEvent = try #require(Self.parser.parse(line: approval))
        #expect(approvalEvent.kind == .screenCaptureApproval)
        #expect(approvalEvent.actor == "ScreenCaptureApprovalUI")

        let sharing = try Self.syntheticLine(
            processImagePath: "/System/Library/CoreServices/RemoteManagement/screensharingd.bundle/Contents/MacOS/screensharingd",
            eventMessage: "Starting session"
        )
        let sharingEvent = try #require(Self.parser.parse(line: sharing))
        #expect(sharingEvent.kind == .remoteControlSession)
        #expect(sharingEvent.actor == "screensharingd")
    }

    // MARK: - Redaction

    @Test func testRedactedFieldsFallback() throws {
        // Hand-edited fixture line: processImagePath redacted, rule matched
        // through the `process` key → actor falls back to the process name.
        let withProcessKey = try Self.fixtureLine(
            containing: ["\"processImagePath\":\"<private>\"", "updateScreenCaptureDidStart"]
        )
        let eventA = try #require(Self.parser.parse(line: withProcessKey))
        #expect(eventA.kind == .screenCapture)
        #expect(eventA.actor == "replayd")
        #expect(eventA.actorPath == nil)

        // Hand-edited fixture line: path redacted and no `process` key,
        // matched through the ScreenCaptureKit subsystem → the actor degrades
        // to "unknown" instead of crashing or dropping the event.
        let subsystemOnly = try Self.fixtureLine(
            containing: ["\"processImagePath\":\"<private>\"", "com.apple.ScreenCaptureKit"]
        )
        let eventB = try #require(Self.parser.parse(line: subsystemOnly))
        #expect(eventB.kind == .screenCapture)
        #expect(eventB.actor == "unknown")
        #expect(eventB.actorPath == nil)
    }

    // MARK: - Malformed input

    @Test func testMalformedLineReturnsNil() throws {
        // The real capture starts with a non-JSON preamble line.
        let preamble = #"Filtering the log data using "subsystem == "com.apple.ScreenCaptureKit" OR process == "replayd""#
        #expect(Self.parser.parse(line: preamble) == nil)

        // The hand-edited fixture line that is cut off mid-object.
        let malformed = try #require(
            try Self.fixtureLines().first { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) == nil },
            "expected exactly one malformed line in the fixture"
        )
        #expect(Self.parser.parse(line: malformed) == nil)

        // A real line truncated again by the test (read-while-writing case).
        let real = try Self.fixtureLine(containing: ["updateScreenCaptureDidStart"])
        #expect(Self.parser.parse(line: String(real.prefix(120))) == nil)

        // Empty / whitespace / non-object JSON / object without a timestamp.
        #expect(Self.parser.parse(line: "") == nil)
        #expect(Self.parser.parse(line: "\n") == nil)
        #expect(Self.parser.parse(line: "null") == nil)
        #expect(Self.parser.parse(line: "[1,2,3]") == nil)
        #expect(Self.parser.parse(line: "{}") == nil)

        let noTimestamp = try Self.syntheticLine(
            processImagePath: "/usr/libexec/replayd",
            eventMessage: "-[SCMediaAttributionManager updateScreenCaptureDidStart:]",
            timestamp: nil
        )
        #expect(Self.parser.parse(line: noTimestamp) == nil)
    }

    // MARK: - Precision: non-candidates stay nil

    @Test func testNonCandidateReturnsNil() throws {
        // WindowManager = Mission Control thumbnails: the system-noise signal,
        // classified later, never a .screenCapture candidate from parsing.
        let missionControl = try Self.fixtureLine(containing: ["Change expose mode missionControl"])
        #expect(Self.parser.parse(line: missionControl) == nil)

        let modelWindowOrder = try Self.fixtureLine(containing: ["Model window order changed"])
        #expect(Self.parser.parse(line: modelWindowOrder) == nil)

        // screencaptureui XPC / prefs chatter is not a capture signal.
        let chatter = try Self.fixtureLine(containing: ["establishing connection to agent"])
        #expect(Self.parser.parse(line: chatter) == nil)

        // A screencapture line that is not ScreenCaptureKit construction.
        let noise = try Self.fixtureLine(containing: ["Retrieve User by ID"])
        #expect(Self.parser.parse(line: noise) == nil)
    }

    @Test func testRulesWithoutProcessOrSubsystemNeverMatch() throws {
        let line = try Self.fixtureLine(containing: ["Model window order changed"])

        // Message-only rule: too loose to be a capture signal, so the parser
        // must ignore the rule entirely.
        let messageOnly = LogLineParser(rules: [
            KindRule(messageContains: ["Model window order"], kind: .screenCapture)
        ])
        #expect(messageOnly.parse(line: line) == nil)

        let empty = LogLineParser(rules: [KindRule(kind: .screenCapture)])
        #expect(empty.parse(line: line) == nil)
    }

    // MARK: - Custom rules

    @Test func testCustomRulesReplaceDefaults() throws {
        let line = try Self.fixtureLine(containing: ["Change expose mode missionControl"])
        #expect(Self.parser.parse(line: line) == nil)

        let custom = LogLineParser(rules: [
            KindRule(process: "WindowManager", messageContains: ["Change expose mode missionControl"], kind: .screenCapture)
        ])
        let event = try #require(custom.parse(line: line))
        #expect(event.kind == .screenCapture)
        #expect(event.actor == "WindowManager")
    }

    // MARK: - Whole-fixture tolerance

    @Test func testEveryFixtureLineParsesWithoutThrowingAndOnlyAsKnownKinds() throws {
        var parsed = 0
        let allowed: Set<EventKind> = [.screenCapture, .screenCaptureApproval, .remoteControlSession]

        for line in try Self.fixtureLines() {
            // Must never throw: read-while-writing gives truncated lines.
            let event = Self.parser.parse(line: line)
            if let event {
                parsed += 1
                #expect(allowed.contains(event.kind), "unexpected kind \(event.kind) for \(line.prefix(120))")
                #expect(!event.actor.isEmpty)
            }
        }

        // 11 real replayd lines + 1 redacted replayd + 1 redacted
        // ScreenCaptureKit line + 5 screencapture SC-construction lines.
        #expect(parsed == 18)
    }
}
