import Foundation
import Testing

import PWCore

/// Tests for `HistoryQuery` (plan T22, spec §6b, acceptance 18): the History
/// window's pure filtering — the tier filter, the `ซ่อน noise` switch, the day
/// range and the search box — over the events the window has already read off
/// disk.
///
/// `filter` has no clock and no I/O: the range arrives as two `Date`s, exactly
/// as the window read it, so the inclusive bounds are asserted as a property of
/// the function instead of through the file system (T8's suite already pins
/// `EvidenceLog.read`'s own window). The fixture is built around a window that
/// holds one event of every tier, the two events sitting exactly on its bounds,
/// and one event on each side of it — so a filter that leaks across a bound or
/// across a tier fails on a named event rather than on a count.
@Suite struct HistoryQueryTests {

    // MARK: - Time helpers

    /// Fixed anchor date, mid-day, far from midnight and DST edges (the same
    /// anchor the exporter's suite uses).
    private static let anchor = Date(timeIntervalSince1970: 1_762_000_000)

    /// A local date `offset` days from the anchor at `hour`:`minute`.
    private static func day(_ offset: Int, hour: Int = 12, minute: Int = 0) -> Date {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: anchor)
        let shifted = calendar.date(byAdding: .day, value: offset, to: start)!
        return calendar.date(byAdding: .minute, value: hour * 60 + minute, to: shifted)!
    }

    // MARK: - Fixtures

    private static func classified(
        ts: Date,
        tier: Tier,
        actor: String,
        kind: EventKind = .screenCapture,
        reason: String = "default",
        path: String? = nil,
        pid: Int32? = nil,
        summary: String? = nil,
        source: EventSource = .logstream,
        count: Int = 1
    ) -> ClassifiedEvent {
        ClassifiedEvent(
            event: RawEvent(
                ts: ts,
                source: source,
                kind: kind,
                actor: actor,
                actorPath: path,
                pid: pid,
                rawSummary: summary
            ),
            tier: tier,
            reason: reason,
            count: count
        )
    }

    /// The dataset every pinned test filters over.
    ///
    /// `all` is deliberately **not** in timestamp order: it is a log's append
    /// order, and the sort test would pass by accident on a pre-sorted input.
    private struct Standard {
        let from: Date
        let to: Date

        let before: ClassifiedEvent
        let atFrom: ClassifiedEvent
        let org: ClassifiedEvent
        let remote: ClassifiedEvent
        let normal: ClassifiedEvent
        let noise: ClassifiedEvent
        let allowlisted: ClassifiedEvent
        let atTo: ClassifiedEvent
        let after: ClassifiedEvent

        /// Everything the window loaded, in append order (9 events).
        var all: [ClassifiedEvent] {
            [normal, atFrom, remote, noise, before, allowlisted, atTo, org, after]
        }

        /// The seven events inside `[from, to]`, **oldest first** — the
        /// fixture's own spelling, reversed where a newest-first answer is
        /// expected.
        var inRangeOldestFirst: [ClassifiedEvent] {
            [atFrom, org, remote, normal, noise, allowlisted, atTo]
        }

        /// The same six, newest first: what an unfiltered query must return.
        var inRangeNewestFirst: [ClassifiedEvent] {
            Array(inRangeOldestFirst.reversed())
        }
    }

    private static func standard() -> Standard {
        let from = day(-2, hour: 0)
        let to = day(0, hour: 12)

        return Standard(
            from: from,
            to: to,
            before: classified(ts: day(-3, hour: 23), tier: .normal, actor: "before-range"),
            atFrom: classified(ts: from, tier: .normal, actor: "at-from"),
            org: classified(
                ts: day(-2, hour: 9),
                tier: .org,
                actor: "TaniumClient",
                reason: "orgPattern:Tanium",
                path: "/Library/ManageEngine/TaniumClient",
                pid: 4321,
                summary: "SCStream start request"
            ),
            remote: classified(
                ts: day(-2, hour: 10),
                tier: .remote,
                actor: "screensharingd",
                kind: .remoteControlSession,
                reason: "remote-control",
                source: .processwatch
            ),
            normal: classified(ts: day(-1, hour: 11), tier: .normal, actor: "screencaptureui", pid: 777),
            noise: classified(
                ts: day(-1, hour: 12),
                tier: .systemNoise,
                actor: "WindowManager",
                reason: "system-noise"
            ),
            allowlisted: classified(
                ts: day(0, hour: 10),
                tier: .allowlist,
                actor: "Photo Booth",
                reason: "allowlist"
            ),
            atTo: classified(ts: to, tier: .normal, actor: "at-to"),
            after: classified(ts: day(0, hour: 13), tier: .normal, actor: "after-range")
        )
    }

    /// One filtered call on the standard dataset, with every control spelled
    /// out so a test states exactly what it is pinning.
    private static func filter(
        _ standard: Standard,
        tiers: Set<Tier>? = nil,
        hideNoise: Bool = false,
        from: Date? = nil,
        to: Date? = nil,
        search: String = ""
    ) -> [ClassifiedEvent] {
        HistoryQuery.filter(
            standard.all,
            tiers: tiers,
            hideNoise: hideNoise,
            from: from ?? standard.from,
            to: to ?? standard.to,
            search: search
        )
    }

    // MARK: - Range

    @Test func testRangeFilter() {
        let standard = Self.standard()
        let result = Self.filter(standard)

        // Inclusive on both bounds (`EvidenceLog.read`'s window): the events at
        // exactly `from` and exactly `to` are in, the neighbours are out.
        #expect(result.contains(standard.atFrom))
        #expect(result.contains(standard.atTo))
        #expect(!result.contains(standard.before))
        #expect(!result.contains(standard.after))
        #expect(result == standard.inRangeNewestFirst)
    }

    @Test func testInvertedRangeReturnsNothing() {
        let standard = Self.standard()
        #expect(Self.filter(standard, from: standard.to, to: standard.from).isEmpty)
    }

    // MARK: - Tier

    @Test func testTierFilter() {
        let standard = Self.standard()

        #expect(Self.filter(standard, tiers: [.org]) == [standard.org])
        #expect(Self.filter(standard, tiers: [.remote]) == [standard.remote])
        #expect(Self.filter(standard, tiers: [.normal]) == [standard.atTo, standard.normal, standard.atFrom])

        // Two tiers at once, still newest first.
        #expect(Self.filter(standard, tiers: [.org, .remote]) == [standard.remote, standard.org])

        // An empty set matches nothing — the window's "ทั้งหมด" is `nil`, so an
        // empty set can only be a mistake, and showing everything would hide it.
        #expect(Self.filter(standard, tiers: []).isEmpty)
    }

    @Test func testNilTiersReturnsAll() {
        let standard = Self.standard()

        // `nil` is "every tier": the same answer as spelling all five out.
        #expect(Self.filter(standard, tiers: nil) == Self.filter(standard, tiers: Set(Tier.allCases)))
        #expect(Self.filter(standard, tiers: nil) == standard.inRangeNewestFirst)
        #expect(Set(Self.filter(standard, tiers: nil).map(\.tier)) == Set(Tier.allCases))
    }

    // MARK: - Noise

    @Test func testHideNoise() {
        let standard = Self.standard()

        let withNoise = Self.filter(standard, hideNoise: false)
        #expect(withNoise.contains(standard.noise))
        #expect(withNoise.contains(standard.allowlisted))

        // SYSTEM_NOISE and ALLOWLIST are the two tiers the app logs but never
        // notifies (spec §5); hiding them hides exactly those two.
        let hidden = Self.filter(standard, hideNoise: true)
        #expect(!hidden.contains(standard.noise))
        #expect(!hidden.contains(standard.allowlisted))
        #expect(
            hidden == [standard.atTo, standard.normal, standard.remote, standard.org, standard.atFrom]
        )

        // The switch is not overridden by an explicit tier request: asking for
        // a hidden tier with "ซ่อน noise" on is empty, not a contradiction.
        #expect(Self.filter(standard, tiers: [.systemNoise, .allowlist], hideNoise: true).isEmpty)
    }

    // MARK: - Search

    @Test func testSearchCaseInsensitiveOverActorKindReason() {
        let standard = Self.standard()

        // actor — both spellings
        #expect(Self.filter(standard, search: "taniumclient") == [standard.org])
        #expect(Self.filter(standard, search: "TANIUM") == [standard.org])
        // a substring hits every matching actor
        #expect(Self.filter(standard, search: "manager") == [standard.noise])

        // the kind's raw value
        #expect(Self.filter(standard, search: "remote-control-session") == [standard.remote])

        // the reason
        #expect(Self.filter(standard, search: "orgPattern") == [standard.org])
        #expect(Self.filter(standard, search: "system-noise") == [standard.noise])

        // nothing matches → nothing, never everything
        #expect(Self.filter(standard, search: "no-such-actor").isEmpty)

        // `rawSummary` is deliberately not a search field: it is free-form log
        // text, and the pin is the three identity fields.
        #expect(Self.filter(standard, search: "SCStream start request").isEmpty)
    }

    @Test func testEmptySearchReturnsAll() {
        let standard = Self.standard()

        // An empty search is no search at all: it adds no constraint of its
        // own, so the answer is exactly the range's answer.
        #expect(Self.filter(standard, search: "").count == standard.inRangeOldestFirst.count)
        #expect(Self.filter(standard, search: "") == standard.inRangeNewestFirst)
    }

    // MARK: - Sorting

    @Test func testSortDescending() {
        let standard = Self.standard()
        let result = Self.filter(standard)

        let timestamps = result.map(\.event.ts)
        #expect(timestamps == timestamps.sorted(by: >), "rows must be newest first")
        #expect(result.first == standard.atTo)
        #expect(result.last == standard.atFrom)

        // The input really was out of order (the fixture's append order is not
        // timestamp order), so the assertion above is not vacuous.
        #expect(standard.all.map(\.event.actor) != standard.inRangeNewestFirst.map(\.event.actor))
    }

    @Test func testEqualTimestampsKeepInputOrder() {
        // A throttled burst shares one timestamp; the log's append order is the
        // only tie-break available, and the table must not shuffle on refresh.
        let ts = Self.day(-1, hour: 10)
        let first = Self.classified(ts: ts, tier: .normal, actor: "first")
        let second = Self.classified(ts: ts, tier: .normal, actor: "second")
        let third = Self.classified(ts: ts, tier: .normal, actor: "third")

        let result = HistoryQuery.filter(
            [first, second, third],
            tiers: nil,
            hideNoise: false,
            from: .distantPast,
            to: .distantFuture,
            search: ""
        )
        #expect(result == [first, second, third])
    }

    // MARK: - Combinations and edges

    @Test func testFiltersCombine() {
        let standard = Self.standard()

        // Two tiers, noise off, and a search that only one of them answers.
        #expect(
            Self.filter(standard, tiers: [.org, .remote], hideNoise: true, search: "screensharing")
                == [standard.remote]
        )
        // A search can still empty a non-empty tier set.
        #expect(Self.filter(standard, tiers: [.org], search: "screensharing").isEmpty)
    }

    @Test func testEmptyInputReturnsEmpty() {
        #expect(
            HistoryQuery.filter(
                [],
                tiers: nil,
                hideNoise: false,
                from: .distantPast,
                to: .distantFuture,
                search: ""
            ).isEmpty
        )
    }

    @Test func testCountsTravelUnchanged() {
        // The query is a filter, not an aggregator: a throttled row keeps its
        // `×N` count (the window's last column) through every control.
        let standard = Self.standard()
        let burst = Self.classified(
            ts: Self.day(-1, hour: 9),
            tier: .normal,
            actor: "replayd",
            count: 7
        )
        let result = HistoryQuery.filter(
            standard.all + [burst],
            tiers: nil,
            hideNoise: false,
            from: standard.from,
            to: standard.to,
            search: "replayd"
        )
        #expect(result.count == 1)
        #expect(result.first?.count == 7)
    }
}
