import Foundation
import Testing

import PWCore

/// Tests for the in-code string table (spec §10: TH default + EN, every UI
/// string lives in `Strings`).
///
/// The two invariants that keep the table honest are `testKeyParity` (both
/// languages define exactly the same keys) and `testPlaceholderCounts` (`%@`
/// placeholders match per key, so a `String(format:)` call cannot trap or drop
/// an argument in one language only). The rest pin the spec §6 copy and the
/// lookups `Test alert` and the menu rely on.
@Suite struct StringsTests {

    /// Number of `%@` placeholders in a format string.
    private static func placeholderCount(_ string: String) -> Int {
        string.components(separatedBy: "%@").count - 1
    }

    // MARK: - Key parity

    @Test func testKeyParity() {
        let th = Strings.keys(for: .th)
        let en = Strings.keys(for: .en)

        #expect(th == en, "th and en must define exactly the same keys")
        #expect(!th.isEmpty, "the string table must not be empty")
    }

    @Test func testEveryKeyHasANonEmptyValueInBothLanguages() {
        for key in Strings.allKeys {
            #expect(!Strings.t(key, .th).isEmpty, "missing th value for \(key)")
            #expect(!Strings.t(key, .en).isEmpty, "missing en value for \(key)")
        }
    }

    // MARK: - Placeholders

    @Test func testPlaceholderCounts() {
        for key in Strings.allKeys {
            let th = Self.placeholderCount(Strings.t(key, .th))
            let en = Self.placeholderCount(Strings.t(key, .en))
            #expect(th == en, "placeholder count differs for \(key): th=\(th) en=\(en)")
        }
    }

    @Test func testEveryPercentSignBelongsToAPlaceholder() {
        // A lone `%` (one that is not part of `%@`) makes `String(format:)`
        // behave unpredictably, so every `%` must carry its `@`.
        for key in Strings.allKeys {
            for language in Language.allCases {
                let value = Strings.t(key, language)
                let percents = value.filter { $0 == "%" }.count
                #expect(
                    percents == Self.placeholderCount(value),
                    "stray % in \(key) (\(language.rawValue))"
                )
            }
        }
    }

    // MARK: - Copy pinned from spec §6

    @Test func testSpecBannerCopyFormats() {
        // Spec §6: "🚨 ส่องจากองค์กร: <actor> — <kind>".
        #expect(Strings.t("banner.org", .th) == "🚨 ส่องจากองค์กร: %@ — %@")

        let th = String(format: Strings.t("banner.org", .th), "Tanium", "screen-capture")
        #expect(th == "🚨 ส่องจากองค์กร: Tanium — screen-capture")

        let en = String(format: Strings.t("banner.org", .en), "Tanium", "screen-capture")
        #expect(en.contains("Tanium"))
        #expect(en.contains("screen-capture"))
    }

    @Test func testSpecMenuAndWarningCopy() {
        // Spec §6 dropdown copy, verbatim.
        #expect(Strings.t("menu.status.idle", .th) == "เฝ้าระวังอยู่ — ไม่มีการส่อง")
        #expect(Strings.t("menu.status.captured", .th) == "กำลังถูกแคปจอโดย %@ (เมื่อ %@ ที่แล้ว)")
        #expect(Strings.t("menu.status.gap", .th) == "⚠️ ไม่ได้เฝ้าช่วง %@–%@")
        #expect(Strings.t("menu.notif.denied", .th) == "notification ปิด — แบนเนอร์ยังทำงาน")
    }

    @Test func testCopyIsActuallyLocalized() {
        // A table that stored the same string twice would pass key parity; the
        // user-visible copy must really differ between th and en.
        #expect(Strings.t("notif.org.title", .th) != Strings.t("notif.org.title", .en))
        #expect(Strings.t("menu.status.idle", .th) != Strings.t("menu.status.idle", .en))
        #expect(Strings.t("banner.org", .th) != Strings.t("banner.org", .en))
    }

    // MARK: - Required keys

    @Test func testRequiredKeysExist() {
        // The keys the plan's T3 interface requires (at minimum).
        let required: Set<String> = [
            "notif.org.title", "notif.org.body",
            "notif.remote.title", "notif.remote.body",
            "notif.normal.title", "notif.normal.body",
            "notif.gap.title", "notif.gap.body",
            "notif.test.body",
            "menu.status.idle", "menu.status.captured", "menu.status.gap",
            "menu.trust", "menu.untrust", "menu.test", "menu.pause.30m",
            "menu.pause.1h", "menu.pause.resume", "menu.calibration",
            "menu.checkup", "menu.export", "menu.openLog", "menu.openConfig",
            "menu.reloadConfig", "menu.about", "menu.quit", "menu.notif.denied",
            "banner.org",
        ]
        for key in required {
            #expect(Strings.allKeys.contains(key), "missing key \(key)")
        }
    }

    @Test func testUserFacingTierKeysExist() {
        // `Test alert` (spec §6) builds these keys from the tier name, e.g.
        // `notif.org.title` from `Tier.org.rawValue.lowercased()`.
        for tier in [Tier.org, Tier.remote, Tier.normal] {
            let name = tier.rawValue.lowercased()
            for suffix in ["title", "body"] {
                let key = "notif.\(name).\(suffix)"
                #expect(Strings.allKeys.contains(key), "missing key \(key)")
            }
        }
    }

    // MARK: - Lookup behaviour

    @Test func testUnknownKeyReturnsTheKeyItself() {
        // Missing copy must degrade to a visible key, never to a crash or "".
        #expect(Strings.t("nopeek.no.such.key", .th) == "nopeek.no.such.key")
        #expect(Strings.t("nopeek.no.such.key", .en) == "nopeek.no.such.key")
    }

    @Test func testDefaultLanguageIsThai() {
        #expect(Strings.defaultLanguage == .th)
        #expect(Strings.t("menu.status.idle") == Strings.t("menu.status.idle", .th))
    }

    @Test func testLanguageRawValues() {
        #expect(Language.th.rawValue == "th")
        #expect(Language.en.rawValue == "en")
        #expect(Set(Language.allCases) == Set([Language.th, Language.en]))
    }
}
