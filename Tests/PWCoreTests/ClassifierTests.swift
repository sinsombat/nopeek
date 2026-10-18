import Foundation
import Testing

import PWCore

@Suite struct ClassifierTests {

    // MARK: - Helpers

    private func rawEvent(
        actor: String,
        actorPath: String? = nil,
        kind: EventKind = .screenCapture
    ) -> RawEvent {
        RawEvent(
            ts: Date(timeIntervalSince1970: 1_762_000_000.125),
            source: .logstream,
            kind: kind,
            actor: actor,
            actorPath: actorPath
        )
    }

    // MARK: - Precedence (spec §5: first match wins, org on top)

    @Test func testOrgFirst() {
        // Deliberate conflict: the same actor sits in every list, org must win
        // (spec §5 — ORG can never be muted or downgraded).
        let classifier = Classifier(
            org: ["WindowManager", "TaniumClient"],
            noise: ["WindowManager", "Dock", "ControlCenter"],
            allowlist: ["WindowManager"],
            remote: ["WindowManager"]
        )
        let classified = classifier.classify(rawEvent(actor: "WindowManager"))
        #expect(classified.tier == .org)
        #expect(classified.reason == "orgPattern:WindowManager")
        #expect(classified.count == 1)
        #expect(classified.event.actor == "WindowManager")
    }

    @Test func testNoiseBeatsAllowlist() {
        let classifier = Classifier(noise: ["Dock"], allowlist: ["Dock"], remote: ["Dock"])
        let classified = classifier.classify(rawEvent(actor: "Dock"))
        #expect(classified.tier == .systemNoise)
        #expect(classified.reason == "system-noise")
    }

    @Test func testAllowlistBeatsRemote() {
        let classifier = Classifier(allowlist: ["screencaptureui"], remote: ["screencaptureui"])
        let classified = classifier.classify(rawEvent(actor: "screencaptureui"))
        #expect(classified.tier == .allowlist)
        #expect(classified.reason == "allowlist")
    }

    @Test func testRemoteTier() {
        let classifier = Classifier(remote: ["screensharingd"])
        let classified = classifier.classify(rawEvent(actor: "screensharingd"))
        #expect(classified.tier == .remote)
        #expect(classified.reason == "remote-control")
        #expect(classified.count == 1)
    }

    @Test func testDefaultNormal() {
        let classifier = Classifier(
            org: ["Tanium"],
            noise: ["Dock"],
            allowlist: ["screencaptureui"],
            remote: ["screensharingd"]
        )
        let classified = classifier.classify(rawEvent(actor: "replayd"))
        #expect(classified.tier == .normal)
        #expect(classified.reason == "default")
        #expect(classified.count == 1)
    }

    // MARK: - Matching: actor OR actorPath, case-insensitive

    @Test func testActorPathMatching() {
        // The actor name matches nothing; only the path hits the org pattern.
        let classifier = Classifier(org: ["/Library/ManageEngine/"])
        let actorOnly = classifier.classify(rawEvent(actor: "dcondemand"))
        #expect(actorOnly.tier == .normal)

        let byPath = classifier.classify(
            rawEvent(actor: "dcondemand", actorPath: "/Library/ManageEngine/AgentMon")
        )
        #expect(byPath.tier == .org)
        #expect(byPath.reason == "orgPattern:/Library/ManageEngine/")
    }

    @Test func testCaseInsensitiveActorMatching() {
        let classifier = Classifier(remote: ["screensharingd"])
        let classified = classifier.classify(rawEvent(actor: "ScreenSharingD"))
        #expect(classified.tier == .remote)
        #expect(classified.reason == "remote-control")
    }

    @Test func testCaseInsensitivePathMatching() {
        let classifier = Classifier(org: ["/library/manageengine/"])
        let classified = classifier.classify(
            rawEvent(actor: "agentmon", actorPath: "/Library/ManageEngine/AgentMon")
        )
        #expect(classified.tier == .org)
        #expect(classified.reason == "orgPattern:/library/manageengine/")
    }

    @Test func testNilActorPathFallsBackToActor() {
        let classifier = Classifier(remote: ["ARDAgent"])
        let classified = classifier.classify(rawEvent(actor: "ARDAgent", actorPath: nil))
        #expect(classified.tier == .remote)
    }

    // MARK: - Edge cases

    @Test func testFirstMatchingPatternIsNamedInReason() {
        let classifier = Classifier(org: ["Tanium", "TaniumClient"])
        let classified = classifier.classify(rawEvent(actor: "TaniumClient"))
        #expect(classified.tier == .org)
        #expect(classified.reason == "orgPattern:Tanium")
    }

    @Test func testEmptyPatternNeverMatches() {
        // A stray "" in config must not turn every event into a top-priority
        // org hit (an empty substring matches everything).
        let classifier = Classifier(org: [""], noise: [""], allowlist: [""], remote: [""])
        let classified = classifier.classify(rawEvent(actor: "replayd"))
        #expect(classified.tier == .normal)
        #expect(classified.reason == "default")
    }
}
