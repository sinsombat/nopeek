import Foundation

// MARK: - MenuIconState

/// The status item's four icon states (spec §6): normal shield, a live
/// observation, a degraded log stream, and paused.
///
/// Ordering between states is pinned in `MenuStateBuilder.iconState`: degraded
/// outranks everything (a dead reader is the one fact the icon must not hide),
/// then a live observation, then pause, then normal.
public enum MenuIconState: String, CaseIterable, Equatable, Sendable {

    /// Nothing is happening; the monitor is watching.
    case normal
    /// An observation is live (spec §6: a non-noise event within 10 s, 60 s
    /// for ORG).
    case active
    /// The `log stream` child is down; the reader is retrying.
    case degraded
    /// NORMAL notifications are suppressed; ORG/REMOTE still alert.
    case paused

    /// SF Symbol drawn in the menu bar. The app maps it through
    /// `NSImage(systemSymbolName:)` and keeps `isTemplate = true`, so the
    /// icon follows light/dark menu-bar styling.
    public var symbolName: String {
        switch self {
        case .normal: "shield"
        case .active: "exclamationmark.shield"
        case .degraded: "exclamationmark.triangle"
        case .paused: "pause.circle"
        }
    }

    /// `Strings` key of the state's tooltip / accessibility text.
    public var tooltipKey: String { "menu.tooltip.\(rawValue)" }
}

// MARK: - MenuState

/// Everything the status menu shows at one moment, as plain values: the icon
/// state + tooltip, the status and gap lines, the recent-event rows and the
/// two trust lists (spec §6).
///
/// `MenuStateBuilder` produces it; the app layer's `MenuBuilder` only turns it
/// into AppKit items, so no menu-row logic lives in the UI code.
public struct MenuState: Equatable, Sendable {

    /// Which of the four icons to show.
    public var icon: MenuIconState
    /// Tooltip for `icon` (localized, via `Strings`).
    public var tooltip: String
    /// Header line: idle or "กำลังถูกแคปจอโดย X (เมื่อ Ns ที่แล้ว)".
    public var statusLine: String
    /// Second header line for the latest monitoring gap; `nil` when there is
    /// none to show (T24 supplies the `GapReport`).
    public var gapLine: String?
    /// Newest-first rows: time + tier + actor + kind (+ `×N` when a throttled
    /// burst was folded in); the empty-state sentence when there are none.
    public var eventRows: [String]
    /// Distinct actors of the recent events, newest first — the `Trust แอปนี้…`
    /// submenu.
    public var trustActors: [String]
    /// Current allowlist entries — the `ยกเลิก trust` submenu.
    public var allowlist: [String]
    /// Whether NORMAL notifications are paused right now.
    public var isPaused: Bool

    public init(
        icon: MenuIconState,
        tooltip: String,
        statusLine: String,
        gapLine: String?,
        eventRows: [String],
        trustActors: [String],
        allowlist: [String],
        isPaused: Bool
    ) {
        self.icon = icon
        self.tooltip = tooltip
        self.statusLine = statusLine
        self.gapLine = gapLine
        self.eventRows = eventRows
        self.trustActors = trustActors
        self.allowlist = allowlist
        self.isPaused = isPaused
    }
}

// MARK: - MenuStateBuilder

/// The status menu's pure logic (T17, spec §6): a function of the app's
/// sampled state — the tray's recent events, the reader's state, the pause
/// flag, the latest gap and the allowlist — with no clock, no I/O and no
/// AppKit, so every row and every icon choice is unit-testable.
///
/// **The observation window** (spec §6): the icon is "active" while a
/// non-noise event sits inside its window — 10 s for every tier, 60 s for ORG
/// (an org observation keeps the red icon a full minute). Following R20, the
/// off-events (`cameraOff` / `micOff`) close an observation rather than report
/// one, so they never light the icon up on their own and never become the
/// status line's actor; they do stay in the recent-events rows and in the
/// trust list. A timestamp a moment ahead of us (clock skew) clamps to age 0
/// instead of hiding the event.
///
/// **The status line** names the newest event that is *still holding the icon
/// active*: with a NORMAL event lapsed at 25 s and an ORG event at 30 s inside
/// the 60 s hold, the line shows the ORG actor — the honest reason the icon is
/// red.
///
/// The gap line is a second header row and appears only when T24 has set a
/// `GapReport`; `nil` leaves the menu exactly as it was before the lifecycle
/// task.
public struct MenuStateBuilder: Sendable {

    /// How long a non-ORG observation keeps the icon active (spec §6: 10 s).
    public static let activeWindowSeconds: TimeInterval = 10

    /// How long an ORG observation keeps the icon active (spec §6: 60 s).
    public static let orgHoldWindowSeconds: TimeInterval = 60

    /// UI language for every produced string (spec §10).
    public let language: Language

    public init(language: Language = Strings.defaultLanguage) {
        self.language = language
    }

    /// The whole menu's state at `now`. `rowTime` / `gapTime` are injectable
    /// only so tests can pin the formats; the defaults are the menu's own
    /// `HH:mm:ss` rows and `HH:mm` gap range.
    public func state(
        recentEvents: [ClassifiedEvent],
        readerState: LogStreamReader.State?,
        paused: Bool,
        gap: GapReport?,
        allowlist: [String],
        now: Date,
        rowTime: @Sendable (Date) -> String = MenuStateBuilder.rowTime,
        gapTime: @Sendable (Date) -> String = MenuStateBuilder.gapTime
    ) -> MenuState {
        let icon = iconState(
            recentEvents: recentEvents,
            readerState: readerState,
            paused: paused,
            now: now
        )
        return MenuState(
            icon: icon,
            tooltip: Strings.t(icon.tooltipKey, language),
            statusLine: statusLine(recentEvents: recentEvents, now: now),
            gapLine: gapLine(gap, time: gapTime),
            eventRows: eventRows(recentEvents, time: rowTime),
            trustActors: trustActors(in: recentEvents),
            allowlist: allowlist,
            isPaused: paused
        )
    }

    // MARK: - Icon

    /// The four-state choice (spec §6), in pinned priority order:
    /// degraded > active observation > paused > normal.
    public func iconState(
        recentEvents: [ClassifiedEvent],
        readerState: LogStreamReader.State?,
        paused: Bool,
        now: Date
    ) -> MenuIconState {
        // A dead log stream is the one state that must not be missed: no
        // detection is happening at all, so it outranks an observation and
        // the pause flag. (`State.degraded` carries the retry delay; the
        // delay never changes the icon.)
        if let readerState, case .degraded = readerState {
            return .degraded
        }
        if liveObservation(in: recentEvents, now: now) != nil {
            return .active
        }
        return paused ? .paused : .normal
    }

    /// A live observation is the newest on-event that is still inside its
    /// tier's window (see the type documentation; `nil` when there is none).
    public func liveObservation(in recentEvents: [ClassifiedEvent], now: Date) -> ClassifiedEvent? {
        recentEvents.first { event in
            guard !Self.isOffEvent(event) else { return false }
            return Self.age(of: event, at: now) < Self.observationWindow(for: event.tier)
        }
    }

    /// True for the R20 off-events, which close an observation instead of
    /// reporting one.
    public static func isOffEvent(_ event: ClassifiedEvent) -> Bool {
        event.event.kind == .cameraOff || event.event.kind == .micOff
    }

    /// The tier's observation window: `orgHoldWindowSeconds` for ORG, the
    /// 10 s `activeWindowSeconds` for everything else.
    public static func observationWindow(for tier: Tier) -> TimeInterval {
        tier == .org ? orgHoldWindowSeconds : activeWindowSeconds
    }

    /// `now - ts`, clamped at 0: a future-dated line (clock skew) reads as
    /// "just arrived" instead of disappearing from the menu.
    private static func age(of event: ClassifiedEvent, at now: Date) -> TimeInterval {
        max(0, now.timeIntervalSince(event.event.ts))
    }

    // MARK: - Status line

    /// Spec §6's header: the idle sentence, or the live observation named with
    /// the age in whole seconds ("เมื่อ 3s ที่แล้ว").
    public func statusLine(recentEvents: [ClassifiedEvent], now: Date) -> String {
        guard let live = liveObservation(in: recentEvents, now: now) else {
            return Strings.t("menu.status.idle", language)
        }
        let seconds = String(Int(Self.age(of: live, at: now)))
        return String(
            format: Strings.t("menu.status.captured", language),
            live.event.actor,
            seconds
        )
    }

    // MARK: - Gap line

    /// The latest gap as "⚠️ ไม่ได้เฝ้าช่วง HH:MM–HH:MM"; `nil` while T24 has
    /// not set a report, so the row simply never appears.
    public func gapLine(
        _ gap: GapReport?,
        time: @Sendable (Date) -> String = MenuStateBuilder.gapTime
    ) -> String? {
        guard let gap else { return nil }
        return String(format: Strings.t("menu.status.gap", language), time(gap.from), time(gap.to))
    }

    // MARK: - Recent event rows

    /// The tray's rows, newest first, capped at `TrayModel.capacity` (10): the
    /// event's local time, tier, actor and kind, with a `×N` suffix when the
    /// Throttler folded repeats into the row. The empty tray renders the
    /// empty-state sentence, so the menu always has something to show.
    public func eventRows(
        _ events: [ClassifiedEvent],
        time: @Sendable (Date) -> String = MenuStateBuilder.rowTime
    ) -> [String] {
        guard !events.isEmpty else {
            return [Strings.t("menu.events.empty", language)]
        }
        return events.prefix(TrayModel.capacity).map { event in
            var row = String(
                format: Strings.t("menu.event.row", language),
                time(event.event.ts),
                event.tier.rawValue,
                event.event.actor,
                event.event.kind.rawValue
            )
            if event.count > 1 {
                row += " " + String(
                    format: Strings.t("menu.event.count", language),
                    String(event.count)
                )
            }
            return row
        }
    }

    // MARK: - Trust lists

    /// The distinct actors of the recent events, newest first — the order the
    /// menu lists them in. Distinctness is exact (the allowlist is stored
    /// verbatim; the Classifier does the case-insensitive matching).
    public func trustActors(in events: [ClassifiedEvent]) -> [String] {
        var seen = Set<String>()
        return events.compactMap { event in
            seen.insert(event.event.actor).inserted ? event.event.actor : nil
        }
    }

    // MARK: - Time formats

    /// `HH:mm:ss`, locale-independent 24 h — the banner's convention, so the
    /// menu and the banner agree about what "when" looks like.
    public static func rowTime(_ date: Date) -> String {
        formatted(date, "HH:mm:ss")
    }

    /// `HH:mm` for the gap range (spec §6: "ช่วง HH:MM–HH:MM").
    public static func gapTime(_ date: Date) -> String {
        formatted(date, "HH:mm")
    }

    /// Formatters are created per call (`DateFormatter` is not `Sendable`);
    /// this runs at most ten times per menu open.
    private static func formatted(_ date: Date, _ format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}
