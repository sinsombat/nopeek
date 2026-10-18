import Foundation

// MARK: - TrayModel

/// The menu bar's "10 events ล่าสุด" state (spec §6): the newest-first list of
/// the events that reached the tray.
///
/// The tray is fed by `Pipeline`'s `.trayUpdate` (every non-noise tier, paused
/// or not) and patched by `.aggregated`: a throttled repeat folds its running
/// `count` into the row that opened the notification window — the menu shows
/// the burst as `×N` on that row instead of adding rows (spec §5: throttling is
/// grouping, not muting, and the evidence log still holds every event).
///
/// Deliberately a value type with no clock, no I/O and no UI: pure logic the
/// app layer (T12 wiring) owns and the status menu (T17) reads.
public struct TrayModel: Equatable, Sendable {

    /// How many events the tray keeps (spec §6: 10).
    public static let capacity = 10

    /// The most recent events of every non-noise tier, newest first.
    public private(set) var events: [ClassifiedEvent]

    public init() {
        self.events = []
    }

    /// Records one tray event at the front, dropping the oldest beyond
    /// `capacity`. The carried `count` is kept as given — normalising it is the
    /// notification path's job, not the tray's.
    public mutating func record(_ e: ClassifiedEvent) {
        events.insert(e, at: 0)
        if events.count > Self.capacity {
            events.removeLast(events.count - Self.capacity)
        }
    }

    /// Folds a throttled repeat into the tray: the most recent row with the
    /// same notification key — `(kind, actor, tier)`, exactly the Throttler's —
    /// gets `count`, keeping its original timestamp (a burst is displayed at
    /// the time it started, spec §6).
    ///
    /// No matching row means nothing to fold into — the first row of that
    /// window was already pushed out of the ten — so this is a deliberate
    /// no-op: the notification for the burst is already on screen, and no row
    /// is added or resurrected.
    public mutating func applyAggregate(_ e: ClassifiedEvent, count: Int) {
        guard let index = events.firstIndex(where: { sameStream($0, e) }) else { return }
        events[index].count = count
    }

    /// `(kind, actor, tier)` identity, mirroring `Throttler`'s key. `actor` is
    /// compared verbatim: the Classifier already matched case-insensitively,
    /// and folding case here would merge rows the evidence log keeps distinct.
    private func sameStream(_ lhs: ClassifiedEvent, _ rhs: ClassifiedEvent) -> Bool {
        lhs.event.kind == rhs.event.kind
            && lhs.event.actor == rhs.event.actor
            && lhs.tier == rhs.tier
    }
}
