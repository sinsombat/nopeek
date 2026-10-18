import Foundation

// MARK: - Language

/// UI language (spec §10). `th` is the default; the config file's `language`
/// key selects `en`. Raw values are the literal strings used in `config.json`.
public enum Language: String, Codable, CaseIterable, Equatable, Sendable {
    case th
    case en
}

// MARK: - NotificationCopy

/// Title + body for one event's notification (spec §6).
///
/// The grouping thread id is *not* here: it lives with `NotificationService`
/// (R10, `nopeek-<tier>`), so each piece of a notification has exactly one
/// source.
public struct NotificationCopy: Equatable, Sendable {
    public let title: String
    public let body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}

// MARK: - Strings

/// The in-code string table (spec §10: every user-visible string — menu,
/// notifications, banners — lives here; no hardcoded UI text anywhere else).
///
/// Keys are flat and dotted by area:
/// - `notif.*`  notification title/body copy, grouped per tier
/// - `menu.*`   status-menu labels and status lines
/// - `banner.*` on-screen banner copy (spec §6)
/// - `app.*`    the product name used for accessibility labels
///
/// `%@` marks a `String(format:)` placeholder. `StringsTests.testKeyParity`
/// pins that both languages define exactly the same keys and
/// `StringsTests.testPlaceholderCounts` that the placeholder counts match per
/// key — a `String(format:)` call site can therefore never be right in one
/// language and wrong in the other.
public enum Strings {

    /// Language used when a caller does not pass one (spec §10: TH default).
    /// Task 10 replaces the call sites' reliance on this with `config.language`.
    public static let defaultLanguage: Language = .th

    /// Localized string for `key`; an unknown key returns itself so missing
    /// copy degrades to a visible key instead of a crash or empty menu row.
    public static func t(_ key: String, _ lang: Language = Strings.defaultLanguage) -> String {
        table[key]?[lang] ?? key
    }

    /// Every key that has a translation in `lang`.
    public static func keys(for lang: Language) -> Set<String> {
        Set(table.compactMap { $0.value[lang] != nil ? $0.key : nil })
    }

    /// Every key in the table, regardless of language.
    public static var allKeys: Set<String> {
        Set(table.keys)
    }

    // MARK: - Notification copy for a classified event

    /// Title + body for one classified event's notification (spec §6): the
    /// per-tier copy with `<actor> — <kind>` substituted, in `lang`.
    ///
    /// `nil` for the tiers that never notify — `SYSTEM_NOISE` and `ALLOWLIST`
    /// are logged and nothing else (spec §5) — so a sink that goes through this
    /// function cannot post copy that does not exist.
    public static func notificationCopy(
        for event: ClassifiedEvent,
        language: Language = Strings.defaultLanguage
    ) -> NotificationCopy? {
        guard let name = tierName(for: event.tier) else { return nil }
        return NotificationCopy(
            title: t("notif.\(name).title", language),
            body: String(
                format: t("notif.\(name).body", language),
                event.event.actor,
                event.event.kind.rawValue
            )
        )
    }

    /// The `notif.<name>.*` key segment per notifying tier: `org` / `remote` /
    /// `normal`. (`Tier.rawValue.lowercased()` would give the same strings for
    /// these three — this switch keeps the mapping explicit and total.)
    private static func tierName(for tier: Tier) -> String? {
        switch tier {
        case .org: "org"
        case .remote: "remote"
        case .normal: "normal"
        case .systemNoise, .allowlist: nil
        }
    }

    /// The table. Both languages must be present for every key.
    ///
    /// Copy that spec §6 spells out literally (banner, status line, warning,
    /// and the English jargon menu items `Test alert` / `Calibration Wizard…` /
    /// `System Checkup…` / `Reload config` / `About` / `Quit`) is reproduced
    /// verbatim for `th`; the remaining `en` values are translations.
    private static let table: [String: [Language: String]] = [
        // MARK: Notifications (spec §6)

        // ORG: the org banner sentence, split into a headline + "actor — kind"
        // detail (the full sentence is `banner.org`).
        "notif.org.title": [.th: "🚨 ส่องจากองค์กร", .en: "🚨 Org is watching"],
        "notif.org.body": [.th: "%@ — %@", .en: "%@ — %@"],
        "notif.remote.title": [.th: "🖥️ ตรวจพบการควบคุมระยะไกล", .en: "🖥️ Remote control detected"],
        "notif.remote.body": [.th: "%@ — %@", .en: "%@ — %@"],
        "notif.normal.title": [.th: "🔔 ตรวจพบกิจกรรม", .en: "🔔 Activity detected"],
        "notif.normal.body": [.th: "%@ — %@", .en: "%@ — %@"],
        // System thread (no tier): monitoring gaps.
        "notif.gap.title": [.th: "⚠️ ไม่ได้เฝ้าช่วงหนึ่ง", .en: "⚠️ Monitoring gap"],
        "notif.gap.body": [.th: "ไม่ได้เฝ้าช่วง %@–%@", .en: "Not watching %@–%@"],
        // `Test alert` body; the placeholder is the tier name (ORG/REMOTE/NORMAL).
        "notif.test.body": [.th: "ทดสอบการแจ้งเตือน — ระดับ %@", .en: "Test alert — %@ tier"],

        // MARK: Status menu (spec §6)

        "menu.status.idle": [.th: "เฝ้าระวังอยู่ — ไม่มีการส่อง", .en: "Watching — nothing detected"],
        "menu.status.captured": [
            .th: "กำลังถูกแคปจอโดย %@ (เมื่อ %@ ที่แล้ว)",
            .en: "Screen capture by %@ (%@ ago)",
        ],
        "menu.status.gap": [.th: "⚠️ ไม่ได้เฝ้าช่วง %@–%@", .en: "⚠️ Not watching %@–%@"],
        "menu.trust": [.th: "Trust แอปนี้…", .en: "Trust this app…"],
        "menu.untrust": [.th: "ยกเลิก trust", .en: "Untrust"],
        "menu.test": [.th: "Test alert", .en: "Test alert"],
        "menu.pause.30m": [.th: "Pause 30 นาที", .en: "Pause 30 minutes"],
        "menu.pause.1h": [.th: "Pause 1 ชั่วโมง", .en: "Pause 1 hour"],
        "menu.pause.resume": [.th: "หยุด pause", .en: "Resume"],
        "menu.calibration": [.th: "Calibration Wizard…", .en: "Calibration Wizard…"],
        "menu.checkup": [.th: "System Checkup…", .en: "System Checkup…"],
        "menu.export": [.th: "Export รายงาน…", .en: "Export report…"],
        "menu.openLog": [.th: "เปิดโฟลเดอร์ log", .en: "Open log folder"],
        "menu.openConfig": [.th: "เปิด config", .en: "Open config"],
        "menu.reloadConfig": [.th: "Reload config", .en: "Reload config"],
        "menu.about": [.th: "About NoPeek", .en: "About NoPeek"],
        "menu.quit": [.th: "Quit NoPeek", .en: "Quit NoPeek"],
        // Shown when notification permission was denied (spec §6) — the banner
        // path does not depend on that permission.
        "menu.notif.denied": [
            .th: "notification ปิด — แบนเนอร์ยังทำงาน",
            .en: "Notifications off — banners still work",
        ],

        // MARK: Banners (spec §6)

        "banner.org": [.th: "🚨 ส่องจากองค์กร: %@ — %@", .en: "🚨 Org is watching: %@ — %@"],
        "banner.remote": [
            .th: "🚨 มีการควบคุมระยะไกล: %@ — %@",
            .en: "🚨 Remote control: %@ — %@",
        ],

        // MARK: App

        "app.name": [.th: "NoPeek", .en: "NoPeek"],
    ]
}
