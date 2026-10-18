import Foundation

// MARK: - Classifier

/// Assigns a `Tier` to a `RawEvent` (spec §5).
///
/// Rule order is fixed and deliberate — the first match wins:
/// org → systemNoise → allowlist → remote → default. `org` sits on top so an
/// ORG hit can never be muted or downgraded, even when the same actor also
/// appears in the noise or allowlist (spec §5; acceptance 6 proves the order
/// with `WindowManager` in `orgPatterns`).
///
/// Matching is a **case-insensitive substring** test against `actor` and, when
/// present, `actorPath` — a hit on either counts. The `reason` records what
/// won: `orgPattern:<pattern>` (the first org pattern that matched, in list
/// order), `system-noise`, `allowlist`, `remote-control`, or `default`.
///
/// Pure logic: no I/O, no singletons, value semantics. `count` is always 1 —
/// grouping is the Throttler's job, not the classifier's.
public struct Classifier: Sendable {

    /// Org / RMM patterns; checked first and never overridable.
    public let orgPatterns: [String]
    /// macOS's own window-management chatter; logged, never notified.
    public let noisePatterns: [String]
    /// Actors the user explicitly trusts.
    public let allowlistPatterns: [String]
    /// Remote-control watchlist.
    public let remotePatterns: [String]

    public init(
        org: [String] = [],
        noise: [String] = [],
        allowlist: [String] = [],
        remote: [String] = []
    ) {
        self.orgPatterns = org
        self.noisePatterns = noise
        self.allowlistPatterns = allowlist
        self.remotePatterns = remote
    }

    /// Classifies one event. Never fails; the fallback tier is `.normal`.
    public func classify(_ raw: RawEvent) -> ClassifiedEvent {
        let actor = raw.actor.lowercased()
        let path = raw.actorPath?.lowercased()

        // An empty pattern is ignored rather than matched: `contains("")` is
        // vacuously true, and a stray "" in an org list would silently turn
        // every event into an un-mutable ORG (spec §5 protects ORG from mute).
        func matches(_ pattern: String) -> Bool {
            guard !pattern.isEmpty else { return false }
            let needle = pattern.lowercased()
            return actor.contains(needle) || path?.contains(needle) == true
        }

        if let pattern = orgPatterns.first(where: { matches($0) }) {
            return ClassifiedEvent(event: raw, tier: .org, reason: "orgPattern:\(pattern)", count: 1)
        }
        if noisePatterns.contains(where: { matches($0) }) {
            return ClassifiedEvent(event: raw, tier: .systemNoise, reason: "system-noise", count: 1)
        }
        if allowlistPatterns.contains(where: { matches($0) }) {
            return ClassifiedEvent(event: raw, tier: .allowlist, reason: "allowlist", count: 1)
        }
        if remotePatterns.contains(where: { matches($0) }) {
            return ClassifiedEvent(event: raw, tier: .remote, reason: "remote-control", count: 1)
        }
        return ClassifiedEvent(event: raw, tier: .normal, reason: "default", count: 1)
    }
}
