import Foundation
import Testing

import PWCore

@Suite struct ModelsTests {

    // MARK: - Raw values (spec §5 tiers, spec §8 log schema)

    @Test func testTierRawValues() {
        #expect(Tier.org.rawValue == "ORG")
        #expect(Tier.remote.rawValue == "REMOTE")
        #expect(Tier.normal.rawValue == "NORMAL")
        #expect(Tier.systemNoise.rawValue == "SYSTEM_NOISE")
        #expect(Tier.allowlist.rawValue == "ALLOWLIST")
        #expect(Set(Tier.allCases.map(\.rawValue)) == Set(["ORG", "REMOTE", "NORMAL", "SYSTEM_NOISE", "ALLOWLIST"]))
    }

    @Test func testEventKindRawValues() {
        #expect(EventKind.screenCapture.rawValue == "screen-capture")
        #expect(EventKind.screenCaptureApproval.rawValue == "screen-capture-approval")
        #expect(EventKind.remoteControlProcess.rawValue == "remote-control-process")
        #expect(EventKind.remoteControlSession.rawValue == "remote-control-session")
        #expect(EventKind.cameraOn.rawValue == "camera-on")
        #expect(EventKind.cameraOff.rawValue == "camera-off")
        #expect(EventKind.micOn.rawValue == "mic-on")
        #expect(EventKind.micOff.rawValue == "mic-off")
        #expect(EventKind.monitorStarted.rawValue == "monitor-started")
        #expect(EventKind.monitorDegraded.rawValue == "monitor-degraded")
        #expect(EventKind.monitorRecovered.rawValue == "monitor-recovered")
        #expect(EventKind.monitorGap.rawValue == "monitor-gap")
        #expect(EventKind.configReloaded.rawValue == "config-reloaded")
        #expect(EventKind.calibrationResult.rawValue == "calibration-result")
        #expect(EventKind.checkupRun.rawValue == "checkup-run")
        #expect(EventKind.exportCreated.rawValue == "export-created")
        #expect(EventKind.heartbeat.rawValue == "heartbeat")
    }

    @Test func testEventSourceRawValues() {
        #expect(EventSource.logstream.rawValue == "logstream")
        #expect(EventSource.processwatch.rawValue == "processwatch")
        #expect(EventSource.camera.rawValue == "camera")
        #expect(EventSource.mic.rawValue == "mic")
        #expect(EventSource.system.rawValue == "system")
    }

    // MARK: - Codable

    @Test func testCodableRoundTrip() throws {
        let raw = RawEvent(
            ts: Date(timeIntervalSince1970: 1_762_000_000.125),
            source: .logstream,
            kind: .screenCapture,
            actor: "screencaptureui",
            actorPath: "/usr/sbin/screencaptureui",
            pid: 1234,
            rawSummary: "SCStream start request"
        )
        let classified = ClassifiedEvent(event: raw, tier: .normal, reason: "default", count: 1)

        let rawData = try JSONEncoder().encode(raw)
        #expect(try JSONDecoder().decode(RawEvent.self, from: rawData) == raw)

        let classifiedData = try JSONEncoder().encode(classified)
        #expect(try JSONDecoder().decode(ClassifiedEvent.self, from: classifiedData) == classified)
    }

    @Test func testCodableRoundTripWithoutOptionalFields() throws {
        let raw = RawEvent(
            ts: Date(timeIntervalSince1970: 1_762_000_000.125),
            source: .system,
            kind: .heartbeat,
            actor: "nopeek"
        )
        #expect(raw.actorPath == nil)
        #expect(raw.pid == nil)
        #expect(raw.rawSummary == nil)

        let rawData = try JSONEncoder().encode(raw)
        #expect(try JSONDecoder().decode(RawEvent.self, from: rawData) == raw)

        let classified = ClassifiedEvent(event: raw, tier: .systemNoise, reason: "system-noise", count: 3)
        let classifiedData = try JSONEncoder().encode(classified)
        #expect(try JSONDecoder().decode(ClassifiedEvent.self, from: classifiedData) == classified)
    }

    @Test func testTimestampsUseISO8601WithFractionalSeconds() throws {
        let seconds: TimeInterval = 1_762_000_000.125
        let raw = RawEvent(
            ts: Date(timeIntervalSince1970: seconds),
            source: .system,
            kind: .monitorGap,
            actor: "nopeek"
        )

        let data = try JSONEncoder().encode(raw)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let ts = try #require(object["ts"] as? String)

        #expect(ts.contains("T"))
        #expect(ts.contains(".125"))

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let parsed = try #require(formatter.date(from: ts))
        #expect(abs(parsed.timeIntervalSince1970 - seconds) <= 0.001)
    }

    @Test func testClassifiedEventEncodesAsFlatEvidenceLogLine() throws {
        // Spec §8: one event = one flat JSON object on a line.
        let raw = RawEvent(
            ts: Date(timeIntervalSince1970: 1_762_000_000.125),
            source: .logstream,
            kind: .screenCapture,
            actor: "screencapture",
            actorPath: "/usr/sbin/screencapture",
            pid: 4321,
            rawSummary: "SCStream start request"
        )
        let classified = ClassifiedEvent(event: raw, tier: .org, reason: "orgPattern:Tanium", count: 2)

        let data = try JSONEncoder().encode(classified)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(
            Set(object.keys) == Set(["ts", "source", "kind", "actor", "actorPath", "pid", "rawSummary", "tier", "reason", "count"])
        )
        #expect(object["event"] == nil)
        #expect(object["kind"] as? String == "screen-capture")
        #expect(object["source"] as? String == "logstream")
        #expect(object["actor"] as? String == "screencapture")
        #expect(object["actorPath"] as? String == "/usr/sbin/screencapture")
        #expect(object["pid"] as? Int == 4321)
        #expect(object["rawSummary"] as? String == "SCStream start request")
        #expect(object["tier"] as? String == "ORG")
        #expect(object["reason"] as? String == "orgPattern:Tanium")
        #expect(object["count"] as? Int == 2)
    }
}
