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
/// **Actions (T21, spec §6).** REMOTE/ORG notifications carry the category
/// `nopeek-alert` with two actions, `Kill` and `ShowLocation`; a button press
/// becomes a `UNNotificationResponse` this type turns into a `KillTarget`
/// (actor / path / pid travel in the content's `userInfo`) and hands to
/// `onAction` on the main actor. The actions themselves — the confirm dialog and
/// the Finder reveal — belong to `AppController`, which sets `onAction`; nothing
/// here kills anything.
///
/// The permission result is cached in `isDenied` so the menu can show the
/// spec §6 warning ("notification ปิด — แบนเนอร์ยังทำงาน").
///
/// **Sound (T23 + spec §6 tier table).** ORG and REMOTE notifications always
/// carry the default sound — an org/remote alert is not something the sound
/// setting may mute into silence. Everything else (NORMAL, and the tier-less
/// monitor-health / auto-kill notices) plays the default sound only while the
/// injected `sound` closure says so. The closure is read on every post, so the
/// Settings window's sound toggle takes effect on the next notification without
/// a relaunch — the same live-config pattern the pipeline's
/// `remoteBannerEnabled` closure uses.
@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {

    /// Grouping thread for monitor-health notifications (no `Tier`): gap,
    /// calibration result, checkup, export (F3). Auto-kill's own notices
    /// (spec §6d) have no tier either and group here too.
    static let systemThreadID = "nopeek-system"

    // MARK: - Alert category (T21)

    /// The category identifier REMOTE/ORG notifications are posted with
    /// (spec §6). The identifier is a wire name — it travels in the
    /// notification and back again — so only the action *titles* are localized.
    static let alertCategoryID = "nopeek-alert"
    static let killActionID = "Kill"
    static let showLocationActionID = "ShowLocation"

    /// What a notification action asks the app to do, with the process it is
    /// about.
    enum Action: Equatable, Sendable {
        case kill(KillTarget)
        case showLocation(KillTarget)
    }

    /// Set once by `AppController` (which owns the kill flow and the reveal).
    /// Called on the main actor, exactly like the menu actions.
    var onAction: (@MainActor (Action) -> Void)?

    /// `nil` when the process has no bundle identifier — running the bare
    /// `swift build` binary makes `UNUserNotificationCenter.current()` trap, so
    /// unbundled runs degrade to no-ops instead of crashing.
    private let center: UNUserNotificationCenter?

    /// `true` once the user has turned notifications off; the menu shows its
    /// warning item while this is set.
    private(set) var isDenied = false

    /// Whether a post should play the default sound, read **live per post**
    /// (T23): the app points this at `configStore.config.sound`, so the
    /// Settings toggle applies without a relaunch. Defaults to `true`, the
    /// spec §7 value, for a caller that does not wire a config.
    private let sound: () -> Bool

    init(sound: @escaping () -> Bool = { true }) {
        self.sound = sound
        if Bundle.main.bundleIdentifier == nil {
            center = nil
        } else {
            center = UNUserNotificationCenter.current()
        }
        super.init()
        center?.delegate = self
    }

    /// Registers the spec §6 alert category (idempotent). Called at launch by
    /// `AppController.start()`, before any event can produce a notification;
    /// calling it again with another language refreshes the action titles
    /// (T23's live language apply).
    ///
    /// The registration **merges**: the set already registered is read back,
    /// this one category is replaced by identifier, everything else is left
    /// alone — a blind `setNotificationCategories([category])` would clobber
    /// any other category a future NoPeek build registers.
    ///
    /// The read is asynchronous and its callback is `@Sendable`, so only the
    /// `String`s the objects are built from cross into it: the center is
    /// re-fetched with `current()` there (the same object — this service only
    /// ever talks to `current()`), and the actions are rebuilt inside.
    func registerAlertCategory(language: Language) {
        guard let center else { return }

        let killID = Self.killActionID
        let killTitle = Strings.t("kill.button.kill", language)
        let revealID = Self.showLocationActionID
        let revealTitle = Strings.t("menu.event.reveal", language)
        let categoryID = Self.alertCategoryID

        center.getNotificationCategories { existing in
            let kill = UNNotificationAction(
                identifier: killID,
                title: killTitle,
                // `.foreground`: the confirm dialog is the point of this
                // action and needs the app in front of the user.
                // `.destructive` because that is exactly what it is.
                options: [.destructive, .foreground]
            )
            let showLocation = UNNotificationAction(
                identifier: revealID,
                title: revealTitle,
                options: []
            )
            let category = UNNotificationCategory(
                identifier: categoryID,
                actions: [kill, showLocation],
                intentIdentifiers: [],
                options: []
            )

            // Read-merge-write: replace only this category, keep the rest.
            var categories = existing.filter { $0.identifier != categoryID }
            categories.insert(category)
            UNUserNotificationCenter.current().setNotificationCategories(categories)
        }
    }

    /// The `userInfo` a REMOTE/ORG notification carries so its actions know what
    /// they are about: only the three fields a kill or a reveal needs.
    nonisolated static func eventUserInfo(actor: String, actorPath: String?, pid: Int32?) -> [String: Any] {
        var info: [String: Any] = ["actor": actor]
        if let actorPath, !actorPath.isEmpty {
            info["actorPath"] = actorPath
        }
        if let pid, pid > 0 {
            info["pid"] = Int(pid)
        }
        return info
    }

    /// The target a notification action names, or `nil` when the payload does
    /// not carry one (a notification posted by an older build, say) — in which
    /// case the action is ignored rather than guessed at.
    nonisolated static func target(from userInfo: [AnyHashable: Any]) -> KillTarget? {
        guard let actor = userInfo["actor"] as? String, !actor.isEmpty else { return nil }
        return KillTarget(
            actor: actor,
            actorPath: userInfo["actorPath"] as? String,
            pid: (userInfo["pid"] as? Int).flatMap { Int32(exactly: $0) }
        )
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

    /// Core post (F3): the caller decides the grouping thread, and — for the
    /// alerts that carry actions (spec §6) — the category and the `userInfo`
    /// its actions need.
    ///
    /// - Parameter sound: `true` forces the default sound, `false` forces
    ///   silence, `nil` (the default) follows the live `sound` closure. The
    ///   tier-based post passes `true` for ORG/REMOTE (spec §6: those alerts
    ///   always sound); a tier-less post leaves it `nil`.
    func post(
        title: String,
        body: String,
        threadID: String,
        categoryID: String? = nil,
        userInfo: [String: Any] = [:],
        sound: Bool? = nil
    ) {
        guard let center else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // Live config (T23): unless the caller forces it (ORG/REMOTE), the
        // Settings window's sound toggle is read here, per post, so turning it
        // off silences the very next notification.
        content.sound = (sound ?? self.sound()) ? .default : nil
        content.threadIdentifier = threadID
        if let categoryID {
            content.categoryIdentifier = categoryID
        }
        if !userInfo.isEmpty {
            content.userInfo = userInfo
        }

        // `trigger: nil` delivers immediately.
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        center.add(request)
    }

    /// Convenience post (F3): groups by tier as `nopeek-<tier>` and attaches
    /// the action-carrying `nopeek-alert` category to the REMOTE and ORG tiers
    /// (spec §6) — the tiers whose rows have `Kill` / `เปิดตำแหน่ง` in the menu.
    ///
    /// Sound follows the spec §6 tier table: ORG and REMOTE always carry it
    /// (forced here, never muted by the `sound` setting); NORMAL follows the
    /// live `sound` closure.
    func post(title: String, body: String, tier: Tier, userInfo: [String: Any] = [:]) {
        post(
            title: title,
            body: body,
            threadID: Self.threadID(for: tier),
            categoryID: Self.carriesAlertActions(tier) ? Self.alertCategoryID : nil,
            userInfo: userInfo,
            sound: Self.carriesAlertActions(tier) ? true : nil
        )
    }

    /// Whether a tier's notifications carry the T21 actions (spec §6:
    /// REMOTE/ORG only — a NORMAL notification has nothing worth killing).
    static func carriesAlertActions(_ tier: Tier) -> Bool {
        tier == .org || tier == .remote
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

    /// A notification action was pressed (spec §6: `Kill` / `ShowLocation` on a
    /// REMOTE/ORG alert). The payload is resolved into a `KillTarget` here — so
    /// only `Sendable` values cross into the `Task` — and handled on the main
    /// actor, where the confirm dialog and Finder live.
    ///
    /// The default action (clicking the notification body) and a dismissal are
    /// not actions: they are ignored. `completionHandler` is called immediately;
    /// the handling itself is asynchronous (it can include a modal dialog).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionID = response.actionIdentifier
        let target = Self.target(from: response.notification.request.content.userInfo)

        Task { @MainActor [weak self] in
            guard let self else { return }
            switch actionID {
            case Self.killActionID:
                if let target { self.onAction?(.kill(target)) }
            case Self.showLocationActionID:
                if let target { self.onAction?(.showLocation(target)) }
            default:
                break
            }
        }
        completionHandler()
    }
}
