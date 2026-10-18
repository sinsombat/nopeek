import Foundation
import Testing

import PWCore

/// Tests for `LogLineParser` (spec §4 log-stream watcher) against a curated
/// slice of a real `log stream --style ndjson` capture taken on 2026-10-18
/// while opening/closing the ⌘⇧5 screenshot toolbar and invoking Mission
/// Control 2–3 times.
///
/// `Tests/PWCoreTests/Fixtures/probe-2026-10-18.ndjson` is the curated subset
/// (the raw 2181-line / 2.2 MB probe stays out of the repo).
///
/// `Tests/PWCoreTests/Fixtures/probe-camera-2026-10-18.ndjson` is the second
/// curated subset, from the camera probe the T14 field-test fix was built on
/// (Photo Booth preview / photo / video / close): the camera rules'
/// start-stop signals and their chatter negatives.
///
/// The tests pin the two halves of spec §5's precision requirement:
/// - **Capture truth signals parse.** `screencapture`'s ScreenCaptureKit
///   construction calls and the *capture-session* variants of replayd
///   (`:165 … hasStarted=1`, the `_block_invoke:186 … screenAttribution
///   complete` lines) must produce events; so must the camera session's own
///   `startRunning`/`stopRunning` lines.
/// - **Everything the probe showed to be ambient must not.** That includes
///   Mission Control's WindowManager chatter (except its one transition line,
///   spec §11-2), `screencaptureui`'s XPC / prefs traffic, **replayd's
///   `:161 client has entitlement to suppress screen indicator` echo** — which
///   a live Mission-Control-only probe showed to be the *only* replayd variant
///   Mission Control produces (ruling R15) — replayd's `hasStarted=0`
///   stream-stop lines (kinds are frozen, nothing consumes a stop), and the
///   camera subsystem's `AVCaptureSession` configuration /
///   `AVControlCenterModules` chatter.
///
/// Three fixture lines are hand-edited cases: a redacted `processImagePath`
/// kept matchable through a synthetic `process` key (on the capture-session
/// variant), a redacted path matched through the `com.apple.ScreenCaptureKit`
/// subsystem, and a JSON line truncated mid-object. The non-JSON preamble line
/// is an inline string (it is text, not ndjson).
@Suite struct LogLineParserTests {

    // MARK: - Helpers

    /// Parser under test: the shipped default rules (screen + camera), exactly
    /// what `AppController` builds. Passing no rules is deliberate — a
    /// regression that un-wires `KindRule.defaults` must fail here.
    private static let parser = LogLineParser()

    private static func fixtureLines() throws -> [String] {
        try fixtureLines(named: "probe-2026-10-18")
    }

    /// The camera probe's curated subset (see the suite documentation).
    private static func fixtureCameraLines() throws -> [String] {
        try fixtureLines(named: "probe-camera-2026-10-18")
    }

    private static func fixtureLines(named name: String) throws -> [String] {
        let url = try #require(
            Bundle.module.url(
                forResource: name,
                withExtension: "ndjson",
                subdirectory: "Fixtures"
            ),
            "fixture Fixtures/\(name).ndjson missing from the test bundle"
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

    /// The millisecond value the fixture's `2026-10-18 10:31:55.975472+0700`
    /// (the replayd capture-session line) corresponds to, built without
    /// reusing the parser's own date code.
    private static func expectedReportedTimestamp() throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try #require(formatter.date(from: "2026-10-18T03:31:55.975Z"))
    }

    // MARK: - Real capture lines

    @Test func testParsesReplaydCaptureSessionLine() throws {
        // replayd's capture-session variant: a real capture started a stream
        // (`hasStarted=1`). Its `:161` sibling — "client has entitlement to
        // suppress screen indicator" — is deliberately *not* a candidate: a
        // live Mission-Control-only probe (ruling R15) showed it is the only
        // replayd line Mission Control produces.
        let line = try Self.fixtureLine(
            containing: ["updateScreenCaptureDidStart", "hasStarted=1"]
        )
        let event = try #require(Self.parser.parse(line: line))

        #expect(event.kind == .screenCapture)
        #expect(event.source == .logstream)
        #expect(event.actor == "replayd")
        #expect(event.actorPath == "/usr/libexec/replayd")
        #expect(event.pid == 97030)

        let summary = try #require(event.rawSummary)
        #expect(summary.contains("updateScreenCaptureDidStart"))
        #expect(summary.contains("hasStarted=1"))
        #expect(summary.count <= 200)
    }

    @Test func testTimestampParsesLogStreamFormat() throws {
        // log stream ndjson timestamps look like
        // "2026-10-18 10:31:55.975472+0700" — space separator, 6-digit
        // fraction, RFC-822 offset (see LogLineParserTests docs).
        let line = try Self.fixtureLine(
            containing: ["updateScreenCaptureDidStart", "hasStarted=1"]
        )
        let event = try #require(Self.parser.parse(line: line))

        let expected = try Self.expectedReportedTimestamp()
        // The parser keeps microseconds; ISO8601 formatting here only carries
        // milliseconds, so allow the sub-millisecond remainder.
        #expect(abs(event.ts.timeIntervalSince(expected)) <= 0.002)
    }

    @Test func testParsesEveryReplaydCaptureSessionLine() throws {
        // The probe holds two capture sessions' worth of session variants:
        // 2 × `hasStarted=1` and 4 × the `:186 … screenAttribution complete`
        // lines (plus the hand-edited redacted copy covered by its own test).
        let lines = try Self.fixtureLines().filter {
            ($0.contains("hasStarted=1") || $0.contains("update screenAttribution complete"))
                && !$0.contains("<private>")
        }
        #expect(lines.count == 6)

        for line in lines {
            let event = try #require(Self.parser.parse(line: line), "line did not parse: \(line.prefix(120))")
            #expect(event.kind == .screenCapture)
            #expect(event.actor == "replayd")
        }
    }

    @Test func testReplaydMissionControlEchoStaysNil() throws {
        // R15: the probe's three `:161 client has entitlement to suppress
        // screen indicator` lines all sit at Mission Control moments
        // (10:30:56.186 +0.17 s after a gesture enter, 10:31:16.23 as its
        // delayed echo, 10:32:32.216 +0.05 s after a hotKey enter), and the
        // live MC-only probe / the pre-fix app both reproduced exactly this
        // variant with no capture session anywhere near. It must not reach
        // the Classifier as a candidate, or Mission Control would notify.
        let echo = try Self.fixtureLines().filter {
            $0.contains("client has entitlement to suppress screen indicator")
        }
        #expect(echo.count == 3, "expected the probe's three :161 lines")

        for line in echo {
            #expect(Self.parser.parse(line: line) == nil, "MC echo parsed: \(line.prefix(120))")
        }
    }

    @Test func testReplaydStopLinesStayNil() throws {
        // `hasStarted=0` is the stream stop. Kinds are frozen (R5: no
        // "capture stopped" kind) and nothing consumes a stop, so the stops
        // are not candidates either — the session's `hasStarted=1` line(s)
        // already carry the capture.
        let stops = try Self.fixtureLines().filter { $0.contains("hasStarted=0") }
        #expect(stops.count == 2, "expected the probe's two stop lines")

        for line in stops {
            #expect(Self.parser.parse(line: line) == nil, "stop line parsed: \(line.prefix(120))")
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

    @Test func testParsesMissionControlTransitionLines() throws {
        // Ruling R14 / spec §11-2: Mission Control must leave SYSTEM_NOISE
        // lines in the evidence log. WindowManager's `app`-category
        // "Change expose mode …" line is the one WindowManager message that is
        // (a) emitted once per Mission Control enter/exit — gesture and
        // hotKey/clientToggle alike, per the raw probe — and (b) not redacted,
        // so the direction is readable in the event.
        for needle in [
            "Change expose mode off -> missionControl",
            "Change expose mode missionControl -> off",
        ] {
            let line = try Self.fixtureLine(containing: [needle])
            let event = try #require(Self.parser.parse(line: line), "no event for \(needle)")
            #expect(event.kind == .screenCapture)
            #expect(event.source == .logstream)
            #expect(event.actor == "WindowManager")
            #expect(
                event.actorPath
                    == "/System/Library/CoreServices/WindowManager.app/Contents/MacOS/WindowManager"
            )
            #expect(event.pid == 1261)
            #expect(event.rawSummary?.contains(needle) == true)
        }
    }

    @Test func testWindowManagerChatterStaysNil() throws {
        // The narrowness of the WM rule is the point: the probe's WindowManager
        // chatter (≈1270 lines) is XPC bookkeeping and private-value state
        // mirrors that carry no readable capture signal, so only the
        // "Change expose mode" line parses.
        for needle in [
            "minimumDockRevealAmountDidChange",
            "AdminXPCListener exposeModeDidChange",
            "Windowing mode: <private>",
        ] {
            let line = try Self.fixtureLine(containing: [needle])
            #expect(Self.parser.parse(line: line) == nil, "WM chatter parsed: \(needle)")
        }
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

    // MARK: - Camera sessions (field-test fix, spec §4-D rework)

    @Test func testShippedDefaultsWireBothSignalFamilies() {
        // The camera rules are only useful if the shipped parser actually
        // carries them: `AppController` constructs `LogLineParser()` with no
        // rules, and a regression to `screenCaptureDefaults` alone would
        // silently disable camera detection while every other test stayed
        // green.
        #expect(LogLineParser().rules == KindRule.defaults)
        #expect(KindRule.defaults == KindRule.screenCaptureDefaults + KindRule.cameraDefaults)
        #expect(KindRule.defaults.contains { $0.kind == .cameraOn })
        #expect(KindRule.defaults.contains { $0.kind == .cameraOff })
    }

    @Test func testCameraStartRunningParsesToCameraOn() throws {
        // The field test's replacement signal: the capturing app logs its own
        // `-[AVCaptureSession_Tundra startRunning]` under
        // com.apple.cameracapture (the plan's `AVCaptureDevice` in-use poll
        // never flipped for the built-in camera). The actor is the capturing
        // process — "Photo Booth" — so org/allowlist patterns match a real app
        // rather than a synthetic "camera".
        let starts = try Self.fixtureCameraLines().filter { $0.contains("startRunning]:") }
        #expect(starts.count == 2, "expected the probe's two session starts")

        for line in starts {
            let event = try #require(Self.parser.parse(line: line), "start line did not parse")
            #expect(event.kind == .cameraOn)
            #expect(event.source == .logstream)
            #expect(event.actor == "Photo Booth")
            #expect(
                event.actorPath
                    == "/System/Applications/Photo Booth.app/Contents/MacOS/Photo Booth"
            )
            #expect(event.pid == 13258)
            #expect(event.rawSummary?.contains("AVCaptureSession_Tundra startRunning]") == true)
            #expect((event.rawSummary ?? "").count <= LogLineParser.rawSummaryLimit)
        }
    }

    @Test func testCameraStopRunningParsesToCameraOff() throws {
        // Three stop lines, including the ~90 ms duplicate pair at the second
        // session's close: two log lines are two observations — the Throttler
        // folds the repeat into one notification (spec §5: throttling is
        // grouping, not muting), the evidence log keeps both.
        let stops = try Self.fixtureCameraLines().filter { $0.contains("stopRunning]:") }
        #expect(stops.count == 3, "expected the probe's three session stops")

        for line in stops {
            let event = try #require(Self.parser.parse(line: line), "stop line did not parse")
            #expect(event.kind == .cameraOff)
            #expect(event.actor == "Photo Booth")
            #expect(event.rawSummary?.contains("AVCaptureSession_Tundra stopRunning]") == true)
        }
    }

    @Test func testCameraChatterStaysNil() throws {
        // Precision is the whole point of the narrowed rule. The probe's other
        // 539 com.apple.cameracapture lines are session configuration and
        // AVControlCenterModules / AVCaptureDALDevice chatter; and the two
        // CoreMediaIO backtrace lines *do* name the selectors while being the
        // same session milliseconds later — if any of them counted as an
        // event, one photo would notify half a dozen times.
        let all = try Self.fixtureCameraLines()
        #expect(all.count == 14, "the camera fixture drifted")

        for needle in [
            // Both backtraces *name the selectors* while being the same session
            // milliseconds later — the subsystem anchor is what excludes them.
            "CMIODeviceStartStream backtrace",
            "CMIODeviceStopStream backtrace",
            "beginConfiguration",
            "commitConfiguration",
            "_buildAndRunGraph",
            "-[AVCaptureDeviceInput_Tundra observeValueForKeyPath",
            "AVControlCenterModulesShouldBeShownForBundleID",
            "AVControlCenterMicrophoneModuleShouldBeShownFor",
            "+[AVCaptureDALDevice _defaultDeviceWithDeviceType",
        ] {
            let line = try #require(
                all.first { $0.contains(needle) },
                "camera fixture is missing the \(needle) negative"
            )
            #expect(Self.parser.parse(line: line) == nil, "camera chatter parsed: \(needle)")
        }
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
        // Raw probe lines around the Mission Control transition that the WM
        // rule deliberately does not match (its XPC neighbours).
        let dockReveal = try Self.fixtureLine(containing: ["minimumDockRevealAmountDidChange"])
        #expect(Self.parser.parse(line: dockReveal) == nil)

        let exposeModeXPC = try Self.fixtureLine(containing: ["AdminXPCListener exposeModeDidChange"])
        #expect(Self.parser.parse(line: exposeModeXPC) == nil)

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
        // A custom rule set replaces the shipped one: the defaults no longer
        // apply, so a line the defaults ignore (general window bookkeeping)
        // parses, while the Mission Control line the defaults do parse stays
        // `nil` here.
        let bookkeeping = try Self.fixtureLine(containing: ["Model window order changed"])
        #expect(Self.parser.parse(line: bookkeeping) == nil)

        let custom = LogLineParser(rules: [
            KindRule(process: "WindowManager", messageContains: ["Model window order"], kind: .screenCapture)
        ])
        let event = try #require(custom.parse(line: bookkeeping))
        #expect(event.kind == .screenCapture)
        #expect(event.actor == "WindowManager")

        let missionControl = try Self.fixtureLine(containing: ["Change expose mode missionControl"])
        #expect(custom.parse(line: missionControl) == nil)
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

        // 6 replayd capture-session variants (2 × hasStarted=1, 4 × :186)
        // + 1 hand-edited redacted replayd session line + 5 screencapture
        // SC-construction lines + 1 redacted ScreenCaptureKit line
        // + 2 Mission Control transition lines (spec §11-2 / ruling R14).
        // The 3 :161 Mission Control echoes and the 2 hasStarted=0 stops are
        // deliberately absent from the count — they are not candidates (R15).
        #expect(parsed == 15)
    }
}
