import Foundation
import Testing

import PWCore

/// Tests for `SettingsDraft` (spec §6c, plan T23): the Settings window's
/// testable half.
///
/// Three things are pinned here:
/// - **the bounds** — retention 1–365, cooldown 0–3600, gap 1–1440,
///   maxPerHour 1–100, `bannerLevel ∈ {floating, screenSaver}`,
///   `language ∈ {th, en}` — each pinned at both edges (inclusive) and just
///   outside them, because the window's promise is "out of range → no write"
///   and a bound that is off by one is exactly the bug that promise hides;
/// - **the list text rule** — one entry per line, trimmed, empties dropped,
///   deduped preserving order (spec §6c: textarea บรรทัดละรายการ);
/// - **the round trip** — `init(config:)` + `apply(to:)` move every editable
///   field and touch nothing else (notably not `replaceDefaultLists`, which
///   spec §6c does not put on the form).
@Suite struct SettingsDraftTests {

    // MARK: - Helpers

    /// A draft whose every field is valid: the *rules* under test are varied
    /// one at a time, so a failure names its own cause.
    private static func validDraft() -> SettingsDraft {
        SettingsDraft(config: NoPeekConfig(
            language: "th",
            sound: true,
            bannerOnForRemote: true,
            bannerLevel: "screenSaver",
            orgBannerCooldownSeconds: 60,
            logRetentionDays: 30,
            gapAlertThresholdMinutes: 15,
            replaceDefaultLists: false,
            orgPatterns: ["PanGPS"],
            remoteControlExtra: ["dwagent"],
            systemNoiseExtra: ["Dock"],
            allowlist: ["/Applications/Trusted.app"],
            autoKillEnabled: true,
            autoKillNames: ["rustdesk"],
            autoKillMaxPerHour: 5
        ))
    }

    // MARK: - Bounds (spec §6c)

    @Test func testRetentionRangeIsOneTo365Inclusive() {
        #expect(SettingsDraft.retentionRange == 1...365)

        var draft = Self.validDraft()
        for value in [1, 2, 365] {
            draft.logRetentionDays = value
            #expect(draft.validate().isEmpty, "day \(value) must be valid")
        }
        for value in [-1, 0, 366, 1000] {
            draft.logRetentionDays = value
            #expect(
                draft.validate() == ["settings.error.retention"],
                "day \(value) must be rejected"
            )
        }
    }

    @Test func testCooldownRangeIsZeroTo3600Inclusive() {
        #expect(SettingsDraft.cooldownRange == 0...3600)

        var draft = Self.validDraft()
        for value in [0, 1, 3600] {
            draft.orgBannerCooldownSeconds = value
            #expect(draft.validate().isEmpty, "\(value)s must be valid")
        }
        for value in [-1, 3601] {
            draft.orgBannerCooldownSeconds = value
            #expect(
                draft.validate() == ["settings.error.cooldown"],
                "\(value)s must be rejected"
            )
        }
    }

    @Test func testGapRangeIsOneTo1440Inclusive() {
        #expect(SettingsDraft.gapRange == 1...1440)

        var draft = Self.validDraft()
        for value in [1, 1440] {
            draft.gapAlertThresholdMinutes = value
            #expect(draft.validate().isEmpty, "\(value) min must be valid")
        }
        for value in [0, 1441] {
            draft.gapAlertThresholdMinutes = value
            #expect(
                draft.validate() == ["settings.error.gap"],
                "\(value) min must be rejected"
            )
        }
    }

    @Test func testMaxPerHourRangeIsOneToHundredInclusive() {
        #expect(SettingsDraft.maxPerHourRange == 1...100)

        var draft = Self.validDraft()
        for value in [1, 100] {
            draft.autoKillMaxPerHour = value
            #expect(draft.validate().isEmpty, "\(value)/hour must be valid")
        }
        for value in [0, 101] {
            draft.autoKillMaxPerHour = value
            #expect(
                draft.validate() == ["settings.error.maxPerHour"],
                "\(value)/hour must be rejected"
            )
        }
    }

    @Test func testBannerLevelMustBeOneOfTheTwoSpecValues() {
        #expect(SettingsDraft.bannerLevels == ["floating", "screenSaver"])

        var draft = Self.validDraft()
        for value in ["floating", "screenSaver"] {
            draft.bannerLevel = value
            #expect(draft.validate().isEmpty, "\(value) must be valid")
        }
        // The popup can only offer the two, but the draft is the thing that
        // guards the file: case variants and anything else are refused.
        for value in ["", "FLOATING", "screensaver", "banner", "floating "] {
            draft.bannerLevel = value
            #expect(
                draft.validate() == ["settings.error.bannerLevel"],
                "\(value.debugDescription) must be rejected"
            )
        }
    }

    @Test func testLanguageMustBeTheTwoSpecValues() {
        #expect(SettingsDraft.languages == ["th", "en"])

        var draft = Self.validDraft()
        for value in ["th", "en"] {
            draft.language = value
            #expect(draft.validate().isEmpty, "\(value) must be valid")
        }
        for value in ["", "TH", "jp", "english", "th-TH"] {
            draft.language = value
            #expect(
                draft.validate() == ["settings.error.language"],
                "\(value.debugDescription) must be rejected"
            )
        }
    }

    @Test func testEveryInvalidFieldIsReportedNotJustTheFirst() {
        var draft = Self.validDraft()
        draft.logRetentionDays = 0
        draft.orgBannerCooldownSeconds = 9999
        draft.autoKillMaxPerHour = 0

        let errors = draft.errors()
        #expect(errors == [.orgBannerCooldownSeconds, .logRetentionDays, .autoKillMaxPerHour])
        #expect(draft.validate() == [
            "settings.error.cooldown",
            "settings.error.retention",
            "settings.error.maxPerHour",
        ])
    }

    @Test func testEachFieldNamesItsOwnCopyKey() {
        // The window attaches a message to a field by this mapping; a field
        // whose key pointed at another rule would show the wrong sentence.
        #expect(SettingsField.language.messageKey == "settings.error.language")
        #expect(SettingsField.bannerLevel.messageKey == "settings.error.bannerLevel")
        #expect(SettingsField.orgBannerCooldownSeconds.messageKey == "settings.error.cooldown")
        #expect(SettingsField.gapAlertThresholdMinutes.messageKey == "settings.error.gap")
        #expect(SettingsField.logRetentionDays.messageKey == "settings.error.retention")
        #expect(SettingsField.autoKillMaxPerHour.messageKey == "settings.error.maxPerHour")

        // ... and every key really exists in the table, both languages.
        for field in SettingsField.allCases {
            #expect(Strings.allKeys.contains(field.messageKey), "missing \(field.messageKey)")
        }
    }

    // MARK: - List text (spec §6c)

    @Test func testParseListTrimsDropsEmptiesAndDedupesInOrder() {
        let text = "  TeamViewer \n\n\tdwagent\t\nTeamViewer\n   \nrustdesk\n\nTeamViewer"
        #expect(SettingsDraft.parseList(text) == ["TeamViewer", "dwagent", "rustdesk"])
    }

    @Test func testParseListHandlesEveryLineBreakAndSingleLineInput() {
        #expect(SettingsDraft.parseList("a\r\nb\rc") == ["a", "b", "c"])
        #expect(SettingsDraft.parseList("only") == ["only"])
        #expect(SettingsDraft.parseList("") == [])
        #expect(SettingsDraft.parseList("\n \n\t\n") == [])
    }

    @Test func testParseListKeepsInnerSpacesAndCaseDistinctEntries() {
        // "b c" is one entry with a space in it (an org path may have one),
        // and "Dock"/"dock" are distinct spellings — exact-string dedupe, the
        // same rule the config's own `dedupePreservingOrder` uses.
        #expect(SettingsDraft.parseList("b c\nDock\ndock") == ["b c", "Dock", "dock"])
    }

    @Test func testRenderThenParseRoundTripsAList() {
        let entries = ["a", "b c", "/Library/ManageEngine/", "TeamViewer"]
        #expect(SettingsDraft.renderList(entries) == "a\nb c\n/Library/ManageEngine/\nTeamViewer")
        #expect(SettingsDraft.parseList(SettingsDraft.renderList(entries)) == entries)
    }

    // MARK: - Config round trip (spec §6c)

    @Test func testDraftFromConfigCarriesEveryEditableField() {
        let config = NoPeekConfig(
            language: "en",
            sound: false,
            bannerOnForRemote: false,
            bannerLevel: "floating",
            orgBannerCooldownSeconds: 0,
            logRetentionDays: 7,
            gapAlertThresholdMinutes: 1,
            replaceDefaultLists: false,
            orgPatterns: ["/Library/ManageEngine/", "PanGPS"],
            remoteControlExtra: ["rustdesk"],
            systemNoiseExtra: [],
            allowlist: ["/Applications/Trusted.app"],
            autoKillEnabled: true,
            autoKillNames: ["dwagent"],
            autoKillMaxPerHour: 3
        )

        let draft = SettingsDraft(config: config)
        #expect(draft.language == "en")
        #expect(draft.sound == false)
        #expect(draft.bannerOnForRemote == false)
        #expect(draft.bannerLevel == "floating")
        #expect(draft.orgBannerCooldownSeconds == 0)
        #expect(draft.logRetentionDays == 7)
        #expect(draft.gapAlertThresholdMinutes == 1)
        #expect(draft.orgPatterns == ["/Library/ManageEngine/", "PanGPS"])
        #expect(draft.remoteControlExtra == ["rustdesk"])
        #expect(draft.systemNoiseExtra.isEmpty)
        #expect(draft.allowlist == ["/Applications/Trusted.app"])
        #expect(draft.autoKillEnabled == true)
        #expect(draft.autoKillNames == ["dwagent"])
        #expect(draft.autoKillMaxPerHour == 3)
    }

    @Test func testDraftFromConfigKeepsListOrderVerbatim() {
        // The file's order is the user's order; dedupe belongs to the text
        // field's parse, not to reading the config back.
        var config = NoPeekConfig.default
        config.orgPatterns = ["b", "a", "b"]

        let draft = SettingsDraft(config: config)
        #expect(draft.orgPatterns == ["b", "a", "b"])
        #expect(draft.validate().isEmpty)
    }

    @Test func testApplyRoundTripsEveryEditableField() {
        let source = NoPeekConfig(
            language: "en",
            sound: false,
            bannerOnForRemote: false,
            bannerLevel: "floating",
            orgBannerCooldownSeconds: 3600,
            logRetentionDays: 365,
            gapAlertThresholdMinutes: 1440,
            replaceDefaultLists: false,
            orgPatterns: ["PanGPS"],
            remoteControlExtra: ["dwagent"],
            systemNoiseExtra: ["Dock"],
            allowlist: ["/Applications/Trusted.app"],
            autoKillEnabled: true,
            autoKillNames: ["rustdesk"],
            autoKillMaxPerHour: 100
        )

        var applied = NoPeekConfig.default
        let draft = SettingsDraft(config: source)
        #expect(draft.validate().isEmpty)
        draft.apply(to: &applied)

        #expect(applied == source)
    }

    @Test func testApplyTouchesOnlyTheEditableFields() {
        // `replaceDefaultLists` is the spec §7 escape hatch and is deliberately
        // not on the form: it is not in the draft, and apply leaves it alone.
        var config = NoPeekConfig.default
        config.replaceDefaultLists = true

        let draft = SettingsDraft(config: NoPeekConfig.default)
        draft.apply(to: &config)

        #expect(config.replaceDefaultLists == true)
        #expect(config == {
            var expected = NoPeekConfig.default
            expected.replaceDefaultLists = true
            return expected
        }())
    }

    @Test func testDefaultConfigIsAValidDraft() {
        let draft = SettingsDraft(config: .default)
        #expect(draft.validate().isEmpty)
        #expect(draft.errors().isEmpty)
    }
}
