import Foundation
import Testing

import PWCore

/// Tests for `AutoKillEngine` (spec §6d loop guard, plan T21).
///
/// The engine is the loop guard: auto-kill may fire at most
/// `autoKillMaxPerHour` times per process name inside a rolling hour, counted
/// per name. Every test drives an injected clock, so "an hour passes" costs
/// nothing and the window arithmetic is pinned exactly.
@Suite struct AutoKillEngineTests {

    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_762_000_000)

        func advance(_ seconds: TimeInterval) {
            now = now.addingTimeInterval(seconds)
        }
    }

    private func engine(maxPerHour: Int = 5, clock: Clock) -> AutoKillEngine {
        AutoKillEngine(maxPerHour: maxPerHour, now: { clock.now })
    }

    // MARK: - Quota

    @Test func testKillUntilTheQuotaIsReached() {
        let clock = Clock()
        let engine = engine(maxPerHour: 5, clock: clock)

        for _ in 0..<5 {
            #expect(engine.evaluate(actor: "screensharingd") == .kill)
        }
        // The sixth appearance of the same name inside the hour is the loop:
        // the guard says stop, and keeps saying it.
        #expect(engine.evaluate(actor: "screensharingd") == .halted)
        #expect(engine.evaluate(actor: "screensharingd") == .halted)
    }

    @Test func testTheWindowSlides() {
        let clock = Clock()
        let engine = engine(maxPerHour: 3, clock: clock)

        for _ in 0..<3 { #expect(engine.evaluate(actor: "rustdesk") == .kill) }
        #expect(engine.evaluate(actor: "rustdesk") == .halted)

        // Half an hour later the window still holds all three.
        clock.advance(30 * 60)
        #expect(engine.evaluate(actor: "rustdesk") == .halted)

        // Past the hour, the first kill has aged out: one slot is free again.
        clock.advance(30 * 60 + 1)
        #expect(engine.evaluate(actor: "rustdesk") == .kill)
        #expect(engine.evaluate(actor: "rustdesk") == .kill)
        #expect(engine.evaluate(actor: "rustdesk") == .kill)
        #expect(engine.evaluate(actor: "rustdesk") == .halted)
    }

    @Test func testTheWindowIsRollingNotFixed() {
        // Kills ten minutes apart: the count slides out one kill at a time, not
        // all at once at some hour boundary.
        let clock = Clock()
        let engine = engine(maxPerHour: 2, clock: clock)

        #expect(engine.evaluate(actor: "AnyDesk") == .kill)
        clock.advance(10 * 60)
        #expect(engine.evaluate(actor: "AnyDesk") == .kill)
        clock.advance(10 * 60)
        #expect(engine.evaluate(actor: "AnyDesk") == .halted)

        // 60 min after the first kill, the first has aged out and the second
        // is still inside the hour: one slot is free, not two.
        clock.advance(40 * 60 + 1) // now: t0 + 60:01
        #expect(engine.evaluate(actor: "AnyDesk") == .kill)   // the t0 kill aged out
        #expect(engine.evaluate(actor: "AnyDesk") == .halted) // the t0+10m kill has not
    }

    @Test func testNamesAreIndependent() {
        let clock = Clock()
        let engine = engine(maxPerHour: 2, clock: clock)

        for _ in 0..<2 { #expect(engine.evaluate(actor: "AnyDesk") == .kill) }
        #expect(engine.evaluate(actor: "AnyDesk") == .halted)

        // A halted name must not hold back a new one.
        #expect(engine.evaluate(actor: "rustdesk") == .kill)
        #expect(engine.evaluate(actor: "rustdesk") == .kill)
        #expect(engine.evaluate(actor: "rustdesk") == .halted)

        // The first name's slide is unaffected by the second's kills.
        clock.advance(60 * 60 + 1)
        #expect(engine.evaluate(actor: "AnyDesk") == .kill)
        #expect(engine.evaluate(actor: "AnyDesk") == .kill)
    }

    // MARK: - Skip

    @Test func testNothingToKillIsASkip() {
        let clock = Clock()

        // A zero/negative quota means auto-kill is effectively off.
        let disabled = engine(maxPerHour: 0, clock: clock)
        #expect(disabled.evaluate(actor: "AnyDesk") == .skip)
        #expect(disabled.evaluate(actor: "AnyDesk") == .skip)

        // An unnamed actor is not something to murder.
        let engine = engine(clock: clock)
        #expect(engine.evaluate(actor: "") == .skip)
        #expect(engine.evaluate(actor: "   ") == .skip)
    }

    @Test func testSkipsDoNotCountAgainstTheQuota() {
        let clock = Clock()
        let engine = engine(maxPerHour: 1, clock: clock)

        #expect(engine.evaluate(actor: "") == .skip)
        #expect(engine.evaluate(actor: " ") == .skip)
        #expect(engine.evaluate(actor: "sleep") == .kill)
        #expect(engine.evaluate(actor: "sleep") == .halted)
    }

    // MARK: - Halt notice (one notification per episode)

    @Test func testTheHaltNoticeIsTakenOncePerEpisode() {
        let clock = Clock()
        let engine = engine(maxPerHour: 2, clock: clock)

        #expect(engine.evaluate(actor: "dwagent") == .kill)
        #expect(engine.evaluate(actor: "dwagent") == .kill)
        #expect(engine.evaluate(actor: "dwagent") == .halted)

        // The app asks once and is answered once: a 3 s poll cannot turn the
        // guard into a notification storm.
        #expect(engine.takeHaltNotice(actor: "dwagent") == true)
        #expect(engine.takeHaltNotice(actor: "dwagent") == false)
        #expect(engine.evaluate(actor: "dwagent") == .halted)
        #expect(engine.takeHaltNotice(actor: "dwagent") == false)

        // The window slides, kills resume, the quota fills again: a *new*
        // episode is worth telling the user about.
        clock.advance(60 * 60 + 1)
        #expect(engine.evaluate(actor: "dwagent") == .kill)
        #expect(engine.takeHaltNotice(actor: "dwagent") == false) // not halted
        #expect(engine.evaluate(actor: "dwagent") == .kill)
        #expect(engine.evaluate(actor: "dwagent") == .halted)
        #expect(engine.takeHaltNotice(actor: "dwagent") == true)
    }

    @Test func testTheHaltNoticeIsPerName() {
        let clock = Clock()
        let engine = engine(maxPerHour: 1, clock: clock)

        #expect(engine.evaluate(actor: "a") == .kill)
        #expect(engine.evaluate(actor: "b") == .kill) // b's own quota, untouched by a
        #expect(engine.evaluate(actor: "a") == .halted)
        #expect(engine.evaluate(actor: "b") == .halted)

        #expect(engine.takeHaltNotice(actor: "a") == true)
        #expect(engine.takeHaltNotice(actor: "a") == false)
        #expect(engine.takeHaltNotice(actor: "b") == true) // a's notice is not b's
    }

    // MARK: - Reads

    @Test func testKillCountFollowsTheWindow() {
        let clock = Clock()
        let engine = engine(maxPerHour: 5, clock: clock)

        #expect(engine.killCount(actor: "sleep") == 0)
        for expected in 1...5 {
            #expect(engine.evaluate(actor: "sleep") == .kill)
            #expect(engine.killCount(actor: "sleep") == expected)
        }
        clock.advance(60 * 60 + 1)
        #expect(engine.killCount(actor: "sleep") == 0)
    }
}
