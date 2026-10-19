import Foundation

// MARK: - SettingsField

/// The editable config fields the Settings form validates (spec §6c, plan T23).
///
/// Only the fields that can *fail* validation are here: the four list keys are
/// text (any content is a legal list once parsed) and the three checkboxes and
/// the two popups cannot produce a value that is out of range. The numeric
/// fields and the two enums are the ones a user can get wrong, and each one
/// names its own copy through `messageKey` — so the window's inline error under
/// a field and the rule that rejected it can never drift apart.
public enum SettingsField: String, CaseIterable, Equatable, Sendable {
    /// `language` — spec §6c; `th` or `en`.
    case language
    /// `bannerLevel` — spec §6; `floating` or `screenSaver`.
    case bannerLevel
    /// Minimum seconds between two org banners.
    case orgBannerCooldownSeconds
    /// Silence longer than this many minutes is a monitoring gap.
    case gapAlertThresholdMinutes
    /// How many days of `events-*.ndjson` to keep.
    case logRetentionDays
    /// Auto-kill's rolling per-name quota (spec §6d).
    case autoKillMaxPerHour

    /// The `Strings` key of this field's rule message, e.g.
    /// `settings.error.retention`. StringsTests pins that the key exists in
    /// both languages for every field.
    public var messageKey: String {
        switch self {
        case .language: "settings.error.language"
        case .bannerLevel: "settings.error.bannerLevel"
        case .orgBannerCooldownSeconds: "settings.error.cooldown"
        case .gapAlertThresholdMinutes: "settings.error.gap"
        case .logRetentionDays: "settings.error.retention"
        case .autoKillMaxPerHour: "settings.error.maxPerHour"
        }
    }
}

// MARK: - SettingsDraft

/// Everything the Settings window edits, as values (spec §6c, plan T23).
///
/// The window is a form over `~/.config/nopeek/config.json`; this type is its
/// testable half: it holds the fields as the user would type them, decides
/// whether they may be written (`validate()` / `errors()`), and moves them
/// into a `NoPeekConfig` (`apply(to:)`) — which is the only place the file is
/// ever touched, through `ConfigStore.update` (ruling F2). A draft that fails
/// validation is therefore never written: the caller checks first, and the
/// save path writes the whole draft or nothing.
///
/// **Pin (spec §6c).** retention 1–365 · cooldown 0–3600 · gap 1–1440 ·
/// maxPerHour 1–100 · `bannerLevel ∈ {floating, screenSaver}` ·
/// `language ∈ {th, en}`. Every bound is inclusive; a value one past either
/// edge is rejected.
///
/// **Lists are text.** The five list keys (the four config lists plus
/// `autoKillNames`) are edited in text areas, one entry per line; `parseList`
/// turns such text into the array the config stores — split on line breaks,
/// trim each line, drop the empty ones, dedupe preserving order (exact string,
/// the same rule `NoPeekConfig.dedupePreservingOrder` applies to the merged
/// built-ins). `renderList` is the way back, so a text area can be filled from
/// a config and parsed back unchanged.
///
/// **`replaceDefaultLists` is deliberately not here.** Spec §6c's field list
/// does not include it, and it is the config file's escape hatch for power
/// users; `apply(to:)` leaves it exactly as it found it.
public struct SettingsDraft: Equatable, Sendable {

    // MARK: - Bounds (spec §6c, pinned by SettingsDraftTests)

    /// `logRetentionDays` (spec §7 default 30).
    public static let retentionRange = 1...365
    /// `orgBannerCooldownSeconds` (spec §7 default 60). 0 disables it.
    public static let cooldownRange = 0...3600
    /// `gapAlertThresholdMinutes` (spec §7 default 15).
    public static let gapRange = 1...1440
    /// `autoKillMaxPerHour` (spec §7 default 5).
    public static let maxPerHourRange = 1...100
    /// The two spec §6 banner levels, in popup order.
    public static let bannerLevels = ["floating", "screenSaver"]
    /// The two spec §10 languages, in popup order.
    public static let languages = ["th", "en"]

    // MARK: - Fields

    /// `"th"` / `"en"` (spec §10).
    public var language: String
    /// Play a sound with notifications (T23 makes it live).
    public var sound: Bool
    /// Show the banner for REMOTE-tier events.
    public var bannerOnForRemote: Bool
    /// `"floating"` / `"screenSaver"`.
    public var bannerLevel: String
    /// Minimum seconds between two org banners.
    public var orgBannerCooldownSeconds: Int
    /// How many days of log files to keep.
    public var logRetentionDays: Int
    /// Silence longer than this many minutes is a monitoring gap.
    public var gapAlertThresholdMinutes: Int
    /// Extra org / RMM patterns (merged with the built-ins).
    public var orgPatterns: [String]
    /// Extra remote-control process names (merged with the built-ins).
    public var remoteControlExtra: [String]
    /// Extra system-noise patterns (merged with the built-ins).
    public var systemNoiseExtra: [String]
    /// Actors the user trusts (passthrough — no built-ins).
    public var allowlist: [String]
    /// The auto-kill opt-in (spec §6d).
    public var autoKillEnabled: Bool
    /// The names auto-kill may kill — typed one by one, never derived.
    public var autoKillNames: [String]
    /// The auto-kill loop guard's rolling per-name quota.
    public var autoKillMaxPerHour: Int

    // MARK: - Life cycle

    /// A draft showing what `config` currently holds — the window's starting
    /// point. Reading is verbatim: a list's order and duplicates are the
    /// file's own (dedupe happens when a text area is parsed for a save).
    public init(config: NoPeekConfig) {
        self.language = config.language
        self.sound = config.sound
        self.bannerOnForRemote = config.bannerOnForRemote
        self.bannerLevel = config.bannerLevel
        self.orgBannerCooldownSeconds = config.orgBannerCooldownSeconds
        self.logRetentionDays = config.logRetentionDays
        self.gapAlertThresholdMinutes = config.gapAlertThresholdMinutes
        self.orgPatterns = config.orgPatterns
        self.remoteControlExtra = config.remoteControlExtra
        self.systemNoiseExtra = config.systemNoiseExtra
        self.allowlist = config.allowlist
        self.autoKillEnabled = config.autoKillEnabled
        self.autoKillNames = config.autoKillNames
        self.autoKillMaxPerHour = config.autoKillMaxPerHour
    }

    // MARK: - Validation

    /// The fields whose current value breaks their rule, in
    /// `SettingsField.allCases` order; empty means the draft may be written.
    public func errors() -> [SettingsField] {
        SettingsField.allCases.filter { field in
            switch field {
            case .language:
                return !Self.languages.contains(language)
            case .bannerLevel:
                return !Self.bannerLevels.contains(bannerLevel)
            case .orgBannerCooldownSeconds:
                return !Self.cooldownRange.contains(orgBannerCooldownSeconds)
            case .gapAlertThresholdMinutes:
                return !Self.gapRange.contains(gapAlertThresholdMinutes)
            case .logRetentionDays:
                return !Self.retentionRange.contains(logRetentionDays)
            case .autoKillMaxPerHour:
                return !Self.maxPerHourRange.contains(autoKillMaxPerHour)
            }
        }
    }

    /// The copy keys of every broken rule (empty = valid). This is what a
    /// caller renders through `Strings`; `errors()` is the same answer with
    /// the field identity kept, which is what a form needs to put the sentence
    /// under the right control.
    public func validate() -> [String] {
        errors().map(\.messageKey)
    }

    // MARK: - Applying

    /// Writes every editable field into `config`. Only the fields on the form
    /// are touched; `replaceDefaultLists` is left alone (see the type note).
    public func apply(to config: inout NoPeekConfig) {
        config.language = language
        config.sound = sound
        config.bannerOnForRemote = bannerOnForRemote
        config.bannerLevel = bannerLevel
        config.orgBannerCooldownSeconds = orgBannerCooldownSeconds
        config.logRetentionDays = logRetentionDays
        config.gapAlertThresholdMinutes = gapAlertThresholdMinutes
        config.orgPatterns = orgPatterns
        config.remoteControlExtra = remoteControlExtra
        config.systemNoiseExtra = systemNoiseExtra
        config.allowlist = allowlist
        config.autoKillEnabled = autoKillEnabled
        config.autoKillNames = autoKillNames
        config.autoKillMaxPerHour = autoKillMaxPerHour
    }

    // MARK: - List text (one entry per line)

    /// A text area's text as the config stores it: split on line breaks
    /// (LF, CR, CRLF), trim each line, drop the empties, dedupe preserving
    /// order.
    public static func parseList(_ text: String) -> [String] {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // Exact-string dedupe, the same rule the config applies to its merged
        // built-ins — so "Dock" and "dock" are two entries (matching itself is
        // case-insensitive at classify time; silently dropping one spelling
        // would be a surprise in the file).
        return NoPeekConfig.dedupePreservingOrder(lines)
    }

    /// The text a text area shows for `entries`: one entry per line, in order.
    /// `parseList(renderList(entries)) == entries` for any list this type
    /// produced (and for any already-trimmed, deduped list).
    public static func renderList(_ entries: [String]) -> String {
        entries.joined(separator: "\n")
    }
}
