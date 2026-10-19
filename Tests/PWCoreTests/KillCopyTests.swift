import Darwin
import Foundation
import Testing

import PWCore

/// Tests for `KillCopy` (spec §6d + §8, plan T21).
///
/// Two kinds of copy come out of this type and they are deliberately different:
/// - the **status line / dialog** copy is user-facing and localized th/en
///   through `Strings` (spec §10);
/// - the **evidence `rawSummary`** is one English line that reads like the
///   spec §8 example (`"manual: SIGTERM delivered to sleep (pid 4242)"`) — the
///   log is the artefact an admin reads, not a UI surface, and it must be
///   greppable: `process-kill` lines carry the initiator, the signal, the name
///   and the pid.
@Suite struct KillCopyTests {

    // MARK: - Evidence summaries

    @Test func testLogSummaryPerOutcome() {
        #expect(
            KillCopy.logSummary(.terminated(signal: SIGTERM), name: "sleep", pid: 4242, initiator: .manual)
                == "manual: SIGTERM delivered to sleep (pid 4242)"
        )
        #expect(
            KillCopy.logSummary(.terminated(signal: SIGKILL), name: "sleep", pid: 4242, initiator: .manual)
                == "manual: SIGKILL delivered to sleep (pid 4242)"
        )
        #expect(
            KillCopy.logSummary(.escalated, name: "sleep", pid: 4242, initiator: .manual)
                == "manual: SIGTERM did not stop sleep (pid 4242) — SIGKILL escalated"
        )
        #expect(
            KillCopy.logSummary(.refusedNameMismatch, name: "sleep", pid: 4242, initiator: .manual)
                == "manual: pid-reuse guard refused 4242 for sleep — no signal sent"
        )
        #expect(
            KillCopy.logSummary(.noPermission, name: "launchd", pid: 1, initiator: .manual)
                == "manual: EPERM on launchd (pid 1) — needs admin"
        )
        #expect(
            KillCopy.logSummary(.noSuchProcess, name: "sleep", pid: 4242, initiator: .manual)
                == "manual: sleep (pid 4242) is already gone"
        )
        #expect(
            KillCopy.logSummary(.failed(errno: EIO), name: "sleep", pid: 4242, initiator: .manual)
                == "manual: kill sleep (pid 4242) failed (errno 5)"
        )
    }

    @Test func testLogSummaryDistinguishesAutoKill() {
        // The loop guard's whole audit trail is these lines: an auto-kill that
        // hit EPERM must be distinguishable from a manual one that was allowed
        // to try the admin prompt.
        #expect(KillCopy.logSummary(.terminated(signal: SIGTERM), name: "sleep", pid: 7, initiator: .auto)
            == "auto-kill: SIGTERM delivered to sleep (pid 7)")
        #expect(KillCopy.logSummary(.escalated, name: "sleep", pid: 7, initiator: .auto)
            == "auto-kill: SIGTERM did not stop sleep (pid 7) — SIGKILL escalated")
        #expect(KillCopy.logSummary(.noPermission, name: "launchd", pid: 1, initiator: .auto)
            == "auto-kill: EPERM on launchd (pid 1) — no admin path (v1)")
        #expect(KillInitiator.manual.rawValue == "manual")
        #expect(KillInitiator.auto.rawValue == "auto-kill")
    }

    @Test func testAdminLogSummaryRecordsAuthorisationOrCancellation() {
        #expect(
            KillCopy.adminLogSummary(success: true, name: "launchd", pid: 1, signal: SIGTERM)
                == "manual: admin elevation authorized — SIGTERM delivered to launchd (pid 1)"
        )
        #expect(
            KillCopy.adminLogSummary(success: false, name: "launchd", pid: 1, signal: SIGKILL)
                == "manual: admin elevation cancelled or failed — launchd (pid 1) not killed"
        )
    }

    // MARK: - User-facing status lines

    @Test func testOutcomeLineIsLocalizedAndNamesTheActor() {
        let terminated = KillCopy.outcomeLine(.terminated(signal: SIGTERM), name: "sleep", language: .th)
        #expect(terminated.contains("sleep"))
        #expect(terminated.contains("SIGTERM"))
        #expect(terminated.hasPrefix("✅"))

        let escalated = KillCopy.outcomeLine(.escalated, name: "sleep", language: .th)
        #expect(escalated.contains("sleep"))
        #expect(escalated.contains("SIGKILL"))

        let denied = KillCopy.outcomeLine(.noPermission, name: "launchd", language: .th)
        #expect(denied.contains("launchd"))

        let gone = KillCopy.outcomeLine(.noSuchProcess, name: "sleep", language: .th)
        #expect(gone.contains("sleep"))

        let refused = KillCopy.outcomeLine(.refusedNameMismatch, name: "sleep", language: .th)
        #expect(refused.contains("sleep"))

        let failed = KillCopy.outcomeLine(.failed(errno: EIO), name: "sleep", language: .th)
        #expect(failed.contains("sleep"))
        #expect(failed.contains("5"))

        // Every outcome has copy in both languages, and EN really differs.
        for outcome in [
            KillOutcome.terminated(signal: SIGTERM), .escalated, .refusedNameMismatch,
            .noPermission, .noSuchProcess, .failed(errno: EIO),
        ] {
            let th = KillCopy.outcomeLine(outcome, name: "sleep", language: .th)
            let en = KillCopy.outcomeLine(outcome, name: "sleep", language: .en)
            #expect(!th.isEmpty)
            #expect(!en.isEmpty)
            #expect(th != en)
        }
    }

    @Test func testAdminLinesAreLocalized() {
        #expect(KillCopy.adminCancelledLine(language: .th) != KillCopy.adminCancelledLine(language: .en))
        #expect(KillCopy.adminResultLine(success: true, name: "launchd", language: .th).contains("launchd"))
        #expect(KillCopy.adminResultLine(success: false, name: "launchd", language: .th).contains("launchd"))
    }

    // MARK: - Auto-kill notifications

    @Test func testAutoKillNotificationCoversTheOutcomesWorthTelling() throws {
        let killed = try #require(
            KillCopy.autoKillNotification(
                .terminated(signal: SIGTERM), name: "sleep", pid: 4242, language: .th
            )
        )
        #expect(killed.title.contains("sleep"))
        #expect(killed.body.contains("SIGTERM"))
        #expect(killed.body.contains("4242"))

        let escalated = try #require(
            KillCopy.autoKillNotification(.escalated, name: "sleep", pid: 4242, language: .th)
        )
        #expect(escalated.title == killed.title)
        #expect(escalated.body.contains("SIGKILL"))

        // The pinned EPERM notice: "kill ไม่ได้ (ต้องสิทธิ์)".
        let denied = try #require(
            KillCopy.autoKillNotification(.noPermission, name: "launchd", pid: 1, language: .th)
        )
        #expect(denied.title == Strings.t("notif.autokill.denied.title", .th))
        #expect(denied.body.contains("launchd"))
        #expect(denied.body.contains("1"))
    }

    @Test func testAutoKillNotificationIsNilForTheSilentOutcomes() {
        // Refusals and misses are log-only: a respawn loop must not turn into a
        // notification loop.
        #expect(KillCopy.autoKillNotification(.refusedNameMismatch, name: "sleep", pid: 1, language: .th) == nil)
        #expect(KillCopy.autoKillNotification(.noSuchProcess, name: "sleep", pid: 1, language: .th) == nil)
        #expect(KillCopy.autoKillNotification(.failed(errno: EIO), name: "sleep", pid: 1, language: .th) == nil)
    }

    @Test func testHaltNotificationNamesTheCount() {
        let copy = KillCopy.haltNotification(name: "dwagent", count: 5, language: .th)
        #expect(copy.title == Strings.t("notif.autokill.halted.title", .th))
        #expect(copy.title == "auto-kill loop — หยุดฆ่าแล้ว")
        #expect(copy.body.contains("dwagent"))
        #expect(copy.body.contains("5"))

        #expect(
            KillCopy.haltLogSummary(name: "dwagent", count: 5)
                == "auto-kill loop guard halted dwagent at 5/hour — no kill"
        )
    }
}
