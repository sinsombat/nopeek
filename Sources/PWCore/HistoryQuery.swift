import Foundation

// MARK: - HistoryQuery

/// The History window's pure filtering (plan T22, spec §6b, acceptance 18): the
/// evidence log read back through the four controls — the tier filter, the
/// `ซ่อน noise` switch, the day range and the search box.
///
/// **It is a function, not a state machine.** `filter` takes the events the
/// window has already loaded off disk and answers "which of these belong on
/// screen, and in what order". No clock, no I/O, no AppKit: the range arrives as
/// two `Date`s exactly as the window read them, so every row on screen is the
/// answer to one pure call. That is what makes the whole visible table
/// unit-testable without a window, a file or a timer.
///
/// **The rules** (applied together; each one only ever narrows the result):
/// - **range** — `event.ts` in `[from, to]`, **both bounds inclusive**, the same
///   window `EvidenceLog.read(from:to:)` uses. A row the read handed over is
///   therefore never dropped by the query for a rounding difference; an inverted
///   range matches nothing.
/// - **tier** — `tiers == nil` means every tier; a set means exactly its
///   members. An empty set matches nothing (the window's "ทั้งหมด" is `nil`, so
///   an empty set can only be a mistake, and answering "everything" would hide
///   it).
/// - **hideNoise** — drops the two tiers the app logs but never notifies
///   (spec §5): `SYSTEM_NOISE` and `ALLOWLIST`.
/// - **search** — case-insensitive substring over the **actor**, the **kind's
///   raw value** and the **reason**, the three fields a user can actually name.
///   An empty search is no search at all. `rawSummary` is deliberately *not*
///   searched: it is free-form log text, and the pin is the three identity
///   fields.
///
/// **Order: newest first.** Ties — one timestamp shared by a throttled burst,
/// or a second-resolution clock — keep the order the events came in
/// (`EvidenceLog.read`'s file and line order), so a 5 s refresh never shuffles
/// rows that share a moment.
public enum HistoryQuery {

    /// The tiers "ซ่อน noise" hides: logged, never notified (spec §5).
    private static let hiddenTiers: Set<Tier> = [.systemNoise, .allowlist]

    /// The events that belong on screen, newest first (see the type's rules).
    public static func filter(
        _ events: [ClassifiedEvent],
        tiers: Set<Tier>?,
        hideNoise: Bool,
        from: Date,
        to: Date,
        search: String
    ) -> [ClassifiedEvent] {
        let needle = search.lowercased()
        let hasSearch = !needle.isEmpty

        return events
            // Positioned before the filter so the sort below can keep ties in
            // the log's own order (there is nothing else to break them with).
            .enumerated()
            .filter { _, event in
                let ts = event.event.ts
                guard ts >= from, ts <= to else { return false }
                if let tiers, !tiers.contains(event.tier) { return false }
                if hideNoise, hiddenTiers.contains(event.tier) { return false }
                guard hasSearch else { return true }
                return event.event.actor.lowercased().contains(needle)
                    || event.event.kind.rawValue.lowercased().contains(needle)
                    || event.reason.lowercased().contains(needle)
            }
            .sorted { lhs, rhs in
                if lhs.element.event.ts != rhs.element.event.ts {
                    return lhs.element.event.ts > rhs.element.event.ts
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}
