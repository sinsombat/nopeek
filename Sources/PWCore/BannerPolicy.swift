import Foundation

// MARK: - BannerPolicy

/// The red banner's per-actor cooldown (spec §5–§6, plan T16).
///
/// A second, independent control next to the `Pipeline`'s tier routing:
///
/// - the **Pipeline** decides *eligibility* per event — ORG always, REMOTE per
///   `bannerOnForRemote`, nothing else (spec §5). It emits `.banner` for every
///   eligible event and never throttles it (`Throttler` gates `.notify` only).
/// - this **policy** decides whether an eligible banner *shows now*. The key is
///   the event's `actor`; a banner that passes opens a `cooldown` window for
///   that actor, and every further ORG/REMOTE event of the same actor inside it
///   is suppressed (spec §5: "event ระหว่าง cooldown ยังได้ notification …
///   แต่ไม่เด้งแบนเนอร์ซ้ำ").
///
/// Consequences, all pinned by `BannerPolicyTests`:
///
/// - The first event of an actor always passes — there is no window yet.
/// - Only ORG and REMOTE are banner tiers; NORMAL / SYSTEM_NOISE / ALLOWLIST
///   return `false` and are **not recorded**, so they can never open, extend or
///   consume a window for an actor that later shows up as ORG.
/// - The window is measured from the last banner that actually *showed*: a
///   suppressed repeat does not push the actor's next show further out, or a
///   steady stream of the same actor would never banner again after the first.
/// - Actors are independent, and the actor is the whole key — a different
///   `kind` from the same actor is still the same banner.
/// - "Within the cooldown" is strictly less than `cooldown`, so an event
///   exactly `cooldown` seconds after the show passes.
/// - A suppressed banner touches **nothing else**: the notification path (and
///   the evidence log, and the tray) already ran in the `Pipeline` and is never
///   affected — `testOrgBannerCooldownSuppressesRepeatButNotNotification` pairs
///   this policy with a real `Pipeline` to pin exactly that.
///
/// Threading: the app calls `shouldShow` from the `Pipeline` sink, which runs on
/// the log reader's one serial queue. State is lock-protected anyway, so the
/// policy is safe to consult from any single ordering context (and
/// `@unchecked Sendable` for storage next to the pipeline).
public final class BannerPolicy: @unchecked Sendable {

    // MARK: - Configuration

    /// Seconds an actor stays quiet after a shown banner (spec §7
    /// `orgBannerCooldownSeconds`, default 60).
    private let cooldown: TimeInterval

    /// The clock. Injected so tests drive time exactly; the app uses the
    /// system clock.
    private let now: () -> Date

    // MARK: - State

    /// Guards `lastShown`: written by `shouldShow` (sink queue), read nowhere
    /// else. The lock keeps a future second caller honest.
    private let lock = NSLock()

    /// Actor → when its banner last actually showed (only passes are stored).
    private var lastShown: [String: Date] = [:]

    // MARK: - Init

    public init(cooldown: TimeInterval = 60, now: @escaping () -> Date = Date.init) {
        self.cooldown = cooldown
        self.now = now
    }

    // MARK: - Decision

    /// `true` when this event should put a banner on screen; `false` when the
    /// actor is still inside its cooldown window (or the tier never banners).
    ///
    /// A `true` result records the show and starts the actor's window; a
    /// `false` result leaves all state untouched.
    public func shouldShow(_ e: ClassifiedEvent) -> Bool {
        switch e.tier {
        case .org, .remote:
            break // the only two banner tiers (spec §5)
        case .normal, .systemNoise, .allowlist:
            return false
        }

        let actor = e.event.actor
        let timestamp = now()

        return lock.withLock {
            if let shown = lastShown[actor], timestamp.timeIntervalSince(shown) < cooldown {
                return false
            }
            lastShown[actor] = timestamp
            return true
        }
    }
}
