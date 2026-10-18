import Foundation

// MARK: - Throttler

/// Groups repeat classified events so one `(kind, actor, tier)` key produces at
/// most one notification per `window`, with a running count (spec §5).
///
/// The rule is a **fixed window anchored on the last `notify`**, not a sliding
/// one: the first event for a key emits `.notify` and opens the window, and
/// every further event for that key until `openedAt + window` emits
/// `.aggregated(count:)` carrying the running total (2, 3, …). Events inside
/// the window never move the deadline — that is the point of the fixed choice:
/// a key that fires every second is not starved forever by its own stream, it
/// notifies again exactly when its window expires, so two notifications for
/// one key are always at least `window` apart — rather than every event
/// pushing the next notification forward by another `window`.
///
/// The window is **half-open**: a `notify` at `t` covers `[t, t + window)`, and
/// an event landing exactly on `t + window` opens the next window. A clock
/// that jumps backwards reads as "inside the window", which at worst delays
/// the next `notify`.
///
/// Grouping is not muting: the Throttler never drops an event, it only says
/// which of them should surface a notification. The caller still receives
/// every event (the evidence log keeps them all, spec §5).
///
/// Pure logic: no I/O, no wall-clock reads of its own — `now` is injected, so
/// tests and the app's wiring control time exactly. A `class` (rather than a
/// `mutating` struct) because `process` keeps per-key state across calls; it is
/// deliberately not thread-safe (one owner drives it, T11).
public final class Throttler {

    // MARK: - Decision

    /// What the caller should do with the event it just processed.
    public enum Decision: Equatable {
        /// First event of a window for its key: surface a notification. The
        /// carried event always has `count == 1`.
        case notify(ClassifiedEvent)
        /// Repeat inside the window: no new notification; fold this event into
        /// the running count the caller is already showing.
        case aggregated(count: Int)
    }

    // MARK: - Configuration

    /// How long one notification covers, in seconds (spec §5: 60 s).
    public let window: TimeInterval

    /// The clock this instance reads. Injected so nothing here depends on the
    /// real clock; the default (`Date.init`) is only for production wiring.
    private let now: () -> Date

    // MARK: - State

    /// The window currently open (or last opened) per key. Entries are kept
    /// after expiry on purpose: an expired entry and a missing one lead to
    /// exactly the same decision, so eviction would only buy a bounded sweep of
    /// the whole dictionary. The key space is the distinct
    /// `(kind, actor, tier)` triples ever seen — actors are process names from
    /// the log predicate, so it stays small.
    private var openWindows: [Key: OpenWindow] = [:]

    /// Identity of one notification stream (spec §5: `(kind, actor, tier)`).
    ///
    /// `actor` is compared verbatim: the Classifier already applied its own
    /// case-insensitive rules, and folding case again here would merge actors
    /// the user may see as distinct in the evidence log.
    private struct Key: Hashable {
        let kind: EventKind
        let actor: String
        let tier: Tier
    }

    private struct OpenWindow {
        /// When the last `.notify` for this key fired — the window runs from
        /// here, not from the most recent event.
        let openedAt: Date
        /// Events folded into this window so far, the notifying one included.
        var count: Int
    }

    // MARK: - Life cycle

    /// - Parameters:
    ///   - window: length of one grouping window in seconds (spec §5: 60).
    ///   - now: source of "now"; defaults to the system clock.
    public init(window: TimeInterval = 60, now: @escaping () -> Date = Date.init) {
        self.window = window
        self.now = now
    }

    // MARK: - Processing

    /// Feeds one classified event through the grouping window and reports what
    /// the caller should do with it.
    ///
    /// O(1) per event — one dictionary lookup and, at most, one insert; no
    /// scanning of the known keys, so a 10,000-event burst stays linear
    /// (Review Focus #5).
    public func process(_ e: ClassifiedEvent) -> Decision {
        let key = Key(kind: e.event.kind, actor: e.event.actor, tier: e.tier)
        let timestamp = now()

        if let open = openWindows[key],
           timestamp.timeIntervalSince(open.openedAt) < window {
            let count = open.count + 1
            openWindows[key] = OpenWindow(openedAt: open.openedAt, count: count)
            return .aggregated(count: count)
        }

        // No window for this key, or the open one has expired: this event is
        // the first of a new window. The carried event is normalised to
        // `count == 1` so `.notify` always means "first event of a window",
        // whatever the caller handed in.
        var first = e
        first.count = 1
        openWindows[key] = OpenWindow(openedAt: timestamp, count: 1)
        return .notify(first)
    }
}
