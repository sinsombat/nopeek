import Foundation
import Testing

import PWCore

/// Tests for the status menu's pure state (T17, spec §6): icon selection,
/// status line, recent-event rows and the trust lists.
///
/// Everything here is a pure function of the inputs the app layer samples —
/// `recentEvents` (newest first, as `TrayModel` keeps them), the reader state,
/// the pause flag, the gap report and the allowlist — measured against one
/// fixed instant, so no test depends on the wall clock or the machine's
/// timezone (the two time formats are injected wherever they matter).
@Suite struct MenuStateBuilderTests {

    /// The instant every test measures from; the clock never moves mid-test.
    private static let now = Date(timeIntervalSince1970: 1_762_000_000)

    /// One classified event `age` seconds before `now`; the tray's newest-first
    /// order is the caller's array order.
    private static func classified(
        tier: Tier,
        kind: EventKind = .screenCapture,
        actor: String = "screencapture",
        age: TimeInterval = 0,
        count: Int = 1
    ) -> ClassifiedEvent {
        ClassifiedEvent(
            event: RawEvent(
                ts: now.addingTimeInterval(-age),
                source: .logstream,
                kind: kind,
                actor: actor
            ),
            tier: tier,
            reason: "test",
            count: count
        )
    }

    private func builder(_ language: Language = .th) -> MenuStateBuilder {
        MenuStateBuilder(language: language)
    }

    // MARK: - Windows and icon mapping

    @Test func testObservationWindowsAreTheSpecWindows() {
        // Spec §6: active for 10 s; an ORG event holds the red icon for 60 s.
        #expect(MenuStateBuilder.activeWindowSeconds == 10)
        #expect(MenuStateBuilder.orgHoldWindowSeconds == 60)
        #expect(MenuStateBuilder.observationWindow(for: .org) == 60)
        for tier in [Tier.remote, .normal, .systemNoise, .allowlist] {
            #expect(MenuStateBuilder.observationWindow(for: tier) == 10)
        }
    }

    @Test func testIconSymbolsAndTooltips() {
        // The four SF Symbols and their `Strings` tooltips (spec §6).
        #expect(MenuIconState.normal.symbolName == "shield")
        #expect(MenuIconState.active.symbolName == "exclamationmark.shield")
        #expect(MenuIconState.degraded.symbolName == "exclamationmark.triangle")
        #expect(MenuIconState.paused.symbolName == "pause.circle")
        #expect(Set(MenuIconState.allCases.map(\.symbolName)).count == 4)

        for state in MenuIconState.allCases {
            #expect(Strings.allKeys.contains(state.tooltipKey), "missing \(state.tooltipKey)")
            #expect(Strings.t(state.tooltipKey, .th) != Strings.t(state.tooltipKey, .en))
        }
    }

    // MARK: - Icon selection

    @Test func testIconIsNormalWithoutEvents() {
        let state = builder().iconState(
            recentEvents: [], readerState: .running, paused: false, now: Self.now
        )
        #expect(state == .normal)
    }

    @Test func testIconShowsActiveObservationInsideTheWindow() {
        for tier in [Tier.org, .remote, .normal] {
            let events = [Self.classified(tier: tier, age: 9)]
            let state = builder().iconState(
                recentEvents: events, readerState: .running, paused: false, now: Self.now
            )
            #expect(state == .active, "tier \(tier.rawValue) at 9 s")
        }
    }

    @Test func testIconLeavesActiveAtTheWindowBoundary() {
        // "ภายใน 10s" is strict: the window is live while age < 10.
        for age in [10.0, 10.5, 30.0] {
            let events = [Self.classified(tier: .normal, age: age)]
            let state = builder().iconState(
                recentEvents: events, readerState: .running, paused: false, now: Self.now
            )
            #expect(state == .normal, "age \(age)")
        }
    }

    @Test func testIconHoldsOrgForSixtySeconds() {
        for age in [10.5, 59.5] {
            let events = [Self.classified(tier: .org, age: age)]
            let state = builder().iconState(
                recentEvents: events, readerState: .running, paused: false, now: Self.now
            )
            #expect(state == .active, "ORG at \(age) s")
        }

        let lapsed = [Self.classified(tier: .org, age: 60)]
        #expect(
            builder().iconState(
                recentEvents: lapsed, readerState: .running, paused: false, now: Self.now
            ) == .normal
        )
    }

    @Test func testIconOnlyOrgGetsTheSixtySecondHold() {
        let events = [Self.classified(tier: .remote, age: 30)]
        #expect(
            builder().iconState(
                recentEvents: events, readerState: .running, paused: false, now: Self.now
            ) == .normal
        )
    }

    @Test func testIconIsPausedWithoutRecentEvents() {
        let state = builder().iconState(
            recentEvents: [], readerState: .running, paused: true, now: Self.now
        )
        #expect(state == .paused)
    }

    @Test func testIconPrefersAnObservationOverPause() {
        // A live capture is the more important truth even while paused; only
        // NORMAL notifications are muted (spec §5).
        let events = [Self.classified(tier: .normal, age: 1)]
        let state = builder().iconState(
            recentEvents: events, readerState: .running, paused: true, now: Self.now
        )
        #expect(state == .active)
    }

    @Test func testIconPrefersDegradedOverEverything() {
        // A dead log stream means detection itself is down: it outranks a live
        // ORG observation and the pause flag.
        let events = [Self.classified(tier: .org, age: 1)]
        let state = builder().iconState(
            recentEvents: events,
            readerState: .degraded(retryIn: 2),
            paused: true,
            now: Self.now
        )
        #expect(state == .degraded)
    }

    @Test func testOffEventsAreNotObservations() {
        // R20/spec §5: cameraOff / micOff close an observation — they are not
        // a new one, so they never light the icon up on their own.
        for kind in [EventKind.cameraOff, .micOff] {
            #expect(
                builder().iconState(
                    recentEvents: [Self.classified(tier: .normal, kind: kind, age: 1)],
                    readerState: .running,
                    paused: false,
                    now: Self.now
                ) == .normal,
                "\(kind.rawValue)"
            )
        }

        // …but an on-event next to them still counts.
        let events = [
            Self.classified(tier: .normal, kind: .cameraOff, actor: "Photo Booth", age: 1),
            Self.classified(tier: .normal, kind: .cameraOn, actor: "Photo Booth", age: 5),
        ]
        #expect(
            builder().iconState(
                recentEvents: events, readerState: .running, paused: false, now: Self.now
            ) == .active
        )
    }

    @Test func testFutureDatedEventsClampToZero() {
        // A log line whose timestamp is a moment ahead of us (clock skew) is
        // still an event that just arrived: age clamps to 0 rather than
        // hiding the icon.
        let events = [Self.classified(tier: .normal, age: -5)]
        #expect(
            builder().iconState(
                recentEvents: events, readerState: .running, paused: false, now: Self.now
            ) == .active
        )
    }

    // MARK: - Status line

    @Test func testStatusLineIsIdleWithoutObservations() {
        #expect(
            builder().statusLine(recentEvents: [], now: Self.now)
                == Strings.t("menu.status.idle", .th)
        )

        let lapsed = [Self.classified(tier: .normal, age: 11)]
        #expect(builder().statusLine(recentEvents: lapsed, now: Self.now) == Strings.t("menu.status.idle", .th))
    }

    @Test func testStatusLineNamesTheLatestActorAndAge() {
        // Spec §6: "กำลังถูกแคปจอโดย X (เมื่อ 3s ที่แล้ว)"; 3.4 s reads as 3.
        let events = [Self.classified(tier: .normal, actor: "replayd", age: 3.4)]
        #expect(
            builder().statusLine(recentEvents: events, now: Self.now)
                == "กำลังถูกแคปจอโดย replayd (เมื่อ 3s ที่แล้ว)"
        )
    }

    @Test func testStatusLineUsesTheEventHoldingTheIconActive() {
        // The NORMAL event has lapsed (25 s > 10); the ORG event still holds
        // the icon (30 s < 60), so the line must name the ORG actor.
        let events = [
            Self.classified(tier: .normal, actor: "screencapture", age: 25),
            Self.classified(tier: .org, actor: "Tanium", age: 30),
        ]
        #expect(
            builder().statusLine(recentEvents: events, now: Self.now)
                == "กำลังถูกแคปจอโดย Tanium (เมื่อ 30s ที่แล้ว)"
        )
    }

    @Test func testStatusLineIsLocalized() {
        let events = [Self.classified(tier: .normal, actor: "replayd", age: 3)]
        #expect(
            builder(.en).statusLine(recentEvents: events, now: Self.now)
                == "Screen capture by replayd (3s ago)"
        )
    }

    @Test func testStatusLineIgnoresOffEvents() {
        let events = [
            Self.classified(tier: .normal, kind: .cameraOff, actor: "Photo Booth", age: 1)
        ]
        #expect(
            builder().statusLine(recentEvents: events, now: Self.now)
                == Strings.t("menu.status.idle", .th)
        )
    }

    // MARK: - Gap line (T24 fills the report; T17 renders it)

    @Test func testGapLineIsNilWithoutAGap() {
        #expect(builder().gapLine(nil) == nil)
    }

    @Test func testGapLineSpansTheReportedRange() {
        let gap = GapReport(from: Self.now.addingTimeInterval(-3_600), to: Self.now, duration: 3_600)
        #expect(builder().gapLine(gap, time: { _ in "T" }) == "⚠️ ไม่ได้เฝ้าช่วง T–T")
        #expect(builder(.en).gapLine(gap, time: { _ in "T" }) == "⚠️ Not watching T–T")
    }

    @Test func testDefaultGapTimeIsHoursAndMinutes() {
        // Loose on purpose: the default formatter uses the machine's timezone.
        let text = MenuStateBuilder.gapTime(Self.now)
        #expect(text.count == 5)
        #expect(text.contains(":"))
    }

    // MARK: - Recent event rows

    @Test func testEventRowsShowTimeTierActorKind() {
        let events = [Self.classified(tier: .normal, actor: "screencapture", age: 0)]
        #expect(
            builder().eventRows(events, time: { _ in "09:41:07" })
                == ["09:41:07  NORMAL  screencapture — screen-capture"]
        )
    }

    @Test func testEventRowsMarkAggregatedCounts() {
        let burst = [Self.classified(tier: .org, actor: "Tanium", count: 3)]
        #expect(
            builder().eventRows(burst, time: { _ in "09:41:07" })
                == ["09:41:07  ORG  Tanium — screen-capture ×3"]
        )

        let single = [Self.classified(tier: .org, actor: "Tanium", count: 1)]
        #expect(
            builder().eventRows(single, time: { _ in "09:41:07" })
                == ["09:41:07  ORG  Tanium — screen-capture"]
        )
    }

    @Test func testEventRowsShowTheEmptyState() {
        #expect(builder().eventRows([]) == ["ยังไม่มีเหตุการณ์"])
        #expect(builder(.en).eventRows([]) == ["No events yet"])
    }

    @Test func testEventRowsCapAtTheTrayCapacity() {
        let events = (0..<12).map { index in
            Self.classified(tier: .normal, actor: "actor-\(index)", age: TimeInterval(index))
        }
        let rows = builder().eventRows(events, time: { _ in "T" })
        #expect(rows.count == TrayModel.capacity)
        #expect(rows.first == "T  NORMAL  actor-0 — screen-capture")
    }

    // MARK: - Trust lists

    @Test func testTrustActorsAreDistinctNewestFirst() {
        let events = [
            Self.classified(tier: .normal, actor: "a", age: 0),
            Self.classified(tier: .normal, actor: "b", age: 1),
            Self.classified(tier: .normal, actor: "a", age: 2),
            Self.classified(tier: .normal, actor: "c", age: 3),
        ]
        #expect(builder().trustActors(in: events) == ["a", "b", "c"])
        #expect(builder().trustActors(in: []) == [])
    }

    @Test func testTrustActorsIncludeOffEventActors() {
        let events = [
            Self.classified(tier: .normal, kind: .cameraOff, actor: "Photo Booth", age: 1),
            Self.classified(tier: .org, actor: "replayd", age: 2),
        ]
        #expect(builder().trustActors(in: events) == ["Photo Booth", "replayd"])
    }

    // MARK: - Aggregate state

    @Test func testStateComposesTheMenuContract() {
        let gap = GapReport(from: Self.now.addingTimeInterval(-3_600), to: Self.now, duration: 3_600)
        let state = builder().state(
            recentEvents: [Self.classified(tier: .org, actor: "Tanium", age: 5)],
            readerState: .running,
            paused: true,
            gap: gap,
            allowlist: ["Tanium"],
            now: Self.now,
            rowTime: { _ in "T" },
            gapTime: { _ in "T" }
        )

        #expect(state.icon == .active)
        #expect(state.tooltip == Strings.t("menu.tooltip.active", .th))
        #expect(state.statusLine == "กำลังถูกแคปจอโดย Tanium (เมื่อ 5s ที่แล้ว)")
        #expect(state.gapLine == "⚠️ ไม่ได้เฝ้าช่วง T–T")
        #expect(state.eventRows == ["T  ORG  Tanium — screen-capture"])
        #expect(state.trustActors == ["Tanium"])
        #expect(state.allowlist == ["Tanium"])
        #expect(state.isPaused)
    }

    @Test func testStateWithoutAGapHasNoGapLine() {
        let state = builder().state(
            recentEvents: [],
            readerState: nil,
            paused: false,
            gap: nil,
            allowlist: [],
            now: Self.now
        )
        #expect(state.icon == .normal)
        #expect(state.gapLine == nil)
        #expect(state.eventRows == ["ยังไม่มีเหตุการณ์"])
    }
}
