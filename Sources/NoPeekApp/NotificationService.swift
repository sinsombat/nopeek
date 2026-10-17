import Foundation
import UserNotifications

import PWCore

/// Notification delivery via `UNUserNotificationCenter` (spec §6).
///
/// Hard constraints baked into this type:
/// - Notification delivery is the only permission NoPeek ever requests; nothing
///   here touches Screen Recording / Accessibility / Full Disk.
/// - Grouping: `post(title:body:tier:)` sets `threadIdentifier = "nopeek-<tier>"`;
///   monitor-health events (gap / calibration / checkup / export) have no tier
///   and use `NotificationService.systemThreadID` (F3).
/// - `.timeSensitive` is never used: it requires an entitlement that ad-hoc
///   builds cannot carry.
///
/// The permission result is cached in `isDenied` so the menu can show the
/// spec §6 warning ("notification ปิด — แบนเนอร์ยังทำงาน").
@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {

    /// Grouping thread for monitor-health notifications (no `Tier`): gap,
    /// calibration result, checkup, export (F3).
    static let systemThreadID = "nopeek-system"

    /// `nil` when the process has no bundle identifier — running the bare
    /// `swift build` binary makes `UNUserNotificationCenter.current()` trap, so
    /// unbundled runs degrade to no-ops instead of crashing.
    private let center: UNUserNotificationCenter?

    /// `true` once the user has turned notifications off; the menu shows its
    /// warning item while this is set.
    private(set) var isDenied = false

    override init() {
        if Bundle.main.bundleIdentifier == nil {
            center = nil
        } else {
            center = UNUserNotificationCenter.current()
        }
        super.init()
        center?.delegate = self
    }

    /// Requests notification permission (spec §6: on first launch). The system
    /// only prompts while the status is `notDetermined`, so later launches are
    /// cheap and never re-prompt after a decision. Returns whether
    /// notifications may be delivered.
    @discardableResult
    func requestPermission() async -> Bool {
        guard let center else { return false }
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            isDenied = !granted
            return granted
        } catch {
            isDenied = true
            return false
        }
    }

    /// Re-reads the system setting without prompting; called before the menu is
    /// shown so revoking access in System Settings surfaces the warning.
    func refreshStatus() async {
        guard let center else { return }
        let status = await center.notificationSettings().authorizationStatus
        isDenied = status == .denied
    }

    /// Core post (F3): the caller decides the grouping thread.
    func post(title: String, body: String, threadID: String) {
        guard let center else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = threadID

        // `trigger: nil` delivers immediately.
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        center.add(request)
    }

    /// Convenience post (F3): groups by tier as `nopeek-<tier>`.
    func post(title: String, body: String, tier: Tier) {
        post(title: title, body: body, threadID: Self.threadID(for: tier))
    }

    /// `nopeek-<tier>` (spec §6 / F3), e.g. `nopeek-org` — kept in step with
    /// `systemThreadID`'s lowercase form.
    static func threadID(for tier: Tier) -> String {
        "nopeek-\(tier.rawValue.lowercased())"
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show the banner even while NoPeek is the active app: a `Test alert`
    /// fired straight from the open menu would otherwise be swallowed as a
    /// "foreground" notification (spec §6: the point of Test alert is to see
    /// that banner + sound work).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}
