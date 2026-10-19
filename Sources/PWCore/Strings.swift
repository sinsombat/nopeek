import Foundation

// MARK: - Language

/// UI language (spec §10). `th` is the default; the config file's `language`
/// key selects `en`. Raw values are the literal strings used in `config.json`.
public enum Language: String, Codable, CaseIterable, Equatable, Sendable {
    case th
    case en
}

// MARK: - NotificationCopy

/// Title + body for one event's notification (spec §6).
///
/// The grouping thread id is *not* here: it lives with `NotificationService`
/// (R10, `nopeek-<tier>`), so each piece of a notification has exactly one
/// source.
public struct NotificationCopy: Equatable, Sendable {
    public let title: String
    public let body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}

// MARK: - Strings

/// The in-code string table (spec §10: every user-visible string — menu,
/// notifications, banners — lives here; no hardcoded UI text anywhere else).
///
/// Keys are flat and dotted by area:
/// - `notif.*`  notification title/body copy, grouped per tier
/// - `menu.*`   status-menu labels, status lines and state tooltips
/// - `banner.*` on-screen banner copy (spec §6)
/// - `kill.*`   the Kill confirm dialog, its status lines and the admin prompt
///              (T21, spec §6d)
/// - `about.*`  the About panel (name/version/limits, spec §13)
/// - `app.*`    the product name used for accessibility labels
///
/// `%@` marks a `String(format:)` placeholder. `StringsTests.testKeyParity`
/// pins that both languages define exactly the same keys and
/// `StringsTests.testPlaceholderCounts` that the placeholder counts match per
/// key — a `String(format:)` call site can therefore never be right in one
/// language and wrong in the other.
public enum Strings {

    /// Language used when a caller does not pass one (spec §10: TH default).
    /// Task 10 replaces the call sites' reliance on this with `config.language`.
    public static let defaultLanguage: Language = .th

    /// Localized string for `key`; an unknown key returns itself so missing
    /// copy degrades to a visible key instead of a crash or empty menu row.
    public static func t(_ key: String, _ lang: Language = Strings.defaultLanguage) -> String {
        table[key]?[lang] ?? key
    }

    /// Every key that has a translation in `lang`.
    public static func keys(for lang: Language) -> Set<String> {
        Set(table.compactMap { $0.value[lang] != nil ? $0.key : nil })
    }

    /// Every key in the table, regardless of language.
    public static var allKeys: Set<String> {
        Set(table.keys)
    }

    // MARK: - Notification copy for a classified event

    /// Title + body for one classified event's notification (spec §6): the
    /// per-tier copy with `<actor> — <kind>` substituted, in `lang`.
    ///
    /// `nil` for the tiers that never notify — `SYSTEM_NOISE` and `ALLOWLIST`
    /// are logged and nothing else (spec §5) — so a sink that goes through this
    /// function cannot post copy that does not exist.
    public static func notificationCopy(
        for event: ClassifiedEvent,
        language: Language = Strings.defaultLanguage
    ) -> NotificationCopy? {
        guard let name = tierName(for: event.tier) else { return nil }
        return NotificationCopy(
            title: t("notif.\(name).title", language),
            body: String(
                format: t("notif.\(name).body", language),
                event.event.actor,
                event.event.kind.rawValue
            )
        )
    }

    /// The `notif.<name>.*` key segment per notifying tier: `org` / `remote` /
    /// `normal`. (`Tier.rawValue.lowercased()` would give the same strings for
    /// these three — this switch keeps the mapping explicit and total.)
    private static func tierName(for tier: Tier) -> String? {
        switch tier {
        case .org: "org"
        case .remote: "remote"
        case .normal: "normal"
        case .systemNoise, .allowlist: nil
        }
    }

    // MARK: - Notification copy for a monitoring gap (T24, spec §4/§5)

    /// Title + body for the startup monitor-gap notification (spec §4): the
    /// monitor reporting that it was not watching, spanning `HH:mm`–`HH:mm`.
    ///
    /// Beside `notificationCopy(for:)` rather than inside it: a gap has no
    /// `Tier` — spec §5 keeps monitor-health notices outside the tier table and
    /// outside `Pause`, and the app posts this one through
    /// `NotificationService` directly. The two times are rendered with
    /// `MenuStateBuilder.gapTime`, the same `HH:mm` the menu's own gap row
    /// uses, so the notice and the row agree about the span.
    public static func gapNotificationCopy(
        for gap: GapReport,
        language: Language = Strings.defaultLanguage
    ) -> NotificationCopy {
        NotificationCopy(
            title: t("notif.gap.title", language),
            body: String(
                format: t("notif.gap.body", language),
                MenuStateBuilder.gapTime(gap.from),
                MenuStateBuilder.gapTime(gap.to)
            )
        )
    }

    /// The table. Both languages must be present for every key.
    ///
    /// Copy that spec §6 spells out literally (banner, status line, warning,
    /// and the English jargon menu items `Test alert` / `Calibration Wizard…` /
    /// `System Checkup…` / `Reload config` / `About` / `Quit`) is reproduced
    /// verbatim for `th`; the remaining `en` values are translations.
    private static let table: [String: [Language: String]] = [
        // MARK: Notifications (spec §6)

        // ORG: the org banner sentence, split into a headline + "actor — kind"
        // detail (the full sentence is `banner.org`).
        "notif.org.title": [.th: "🚨 ส่องจากองค์กร", .en: "🚨 Org is watching"],
        "notif.org.body": [.th: "%@ — %@", .en: "%@ — %@"],
        "notif.remote.title": [.th: "🖥️ ตรวจพบการควบคุมระยะไกล", .en: "🖥️ Remote control detected"],
        "notif.remote.body": [.th: "%@ — %@", .en: "%@ — %@"],
        "notif.normal.title": [.th: "🔔 ตรวจพบกิจกรรม", .en: "🔔 Activity detected"],
        "notif.normal.body": [.th: "%@ — %@", .en: "%@ — %@"],
        // System thread (no tier): monitoring gaps.
        "notif.gap.title": [.th: "⚠️ ไม่ได้เฝ้าช่วงหนึ่ง", .en: "⚠️ Monitoring gap"],
        "notif.gap.body": [.th: "ไม่ได้เฝ้าช่วง %@–%@", .en: "Not watching %@–%@"],
        // `Test alert` body; the placeholder is the tier name (ORG/REMOTE/NORMAL).
        "notif.test.body": [.th: "ทดสอบการแจ้งเตือน — ระดับ %@", .en: "Test alert — %@ tier"],

        // MARK: Status menu (spec §6)

        "menu.status.idle": [.th: "เฝ้าระวังอยู่ — ไม่มีการส่อง", .en: "Watching — nothing detected"],
        "menu.status.captured": [
            .th: "กำลังถูกแคปจอโดย %@ (เมื่อ %@s ที่แล้ว)",
            .en: "Screen capture by %@ (%@s ago)",
        ],
        "menu.status.gap": [.th: "⚠️ ไม่ได้เฝ้าช่วง %@–%@", .en: "⚠️ Not watching %@–%@"],
        // The ten recent tray events: "HH:mm:ss  TIER  actor — kind", with the
        // `menu.event.count` suffix when a throttled burst was folded in.
        "menu.events.empty": [.th: "ยังไม่มีเหตุการณ์", .en: "No events yet"],
        "menu.event.row": [.th: "%@  %@  %@ — %@", .en: "%@  %@  %@ — %@"],
        "menu.event.count": [.th: "×%@", .en: "×%@"],
        "menu.trust": [.th: "Trust แอปนี้…", .en: "Trust this app…"],
        "menu.untrust": [.th: "ยกเลิก trust", .en: "Untrust"],
        // One-line confirmations, shown as the status line for a few seconds
        // (T17 keeps the trust flow notification-free).
        "menu.trust.done": [.th: "เพิ่ม %@ เข้า allowlist แล้ว", .en: "Trusted %@"],
        "menu.untrust.done": [.th: "เอา %@ ออกจาก allowlist แล้ว", .en: "Untrusted %@"],
        "menu.reload.done": [.th: "โหลด config ใหม่แล้ว", .en: "Config reloaded"],
        "menu.config.failed": [.th: "บันทึก config ไม่สำเร็จ", .en: "Could not save the config"],
        "menu.test": [.th: "Test alert", .en: "Test alert"],
        "menu.pause.30m": [.th: "Pause 30 นาที", .en: "Pause 30 minutes"],
        "menu.pause.1h": [.th: "Pause 1 ชั่วโมง", .en: "Pause 1 hour"],
        "menu.pause.resume": [.th: "หยุด pause", .en: "Resume"],
        "menu.calibration": [.th: "Calibration Wizard…", .en: "Calibration Wizard…"],
        "menu.checkup": [.th: "System Checkup…", .en: "System Checkup…"],
        "menu.export": [.th: "Export รายงาน…", .en: "Export report…"],
        "menu.history": [.th: "History…", .en: "History…"],
        "menu.openLog": [.th: "เปิดโฟลเดอร์ log", .en: "Open log folder"],
        "menu.openConfig": [.th: "เปิด config", .en: "Open config"],
        "menu.reloadConfig": [.th: "Reload config", .en: "Reload config"],
        "menu.about": [.th: "About NoPeek", .en: "About NoPeek"],
        "menu.quit": [.th: "Quit NoPeek", .en: "Quit NoPeek"],
        // The four status-item tooltips (T17, spec §6). The name leads so a
        // hover over the menu bar says what the symbol is about.
        "menu.tooltip.normal": [
            .th: "NoPeek — เฝ้าระวังอยู่",
            .en: "NoPeek — watching",
        ],
        "menu.tooltip.active": [
            .th: "NoPeek — กำลังถูกส่องอยู่",
            .en: "NoPeek — being observed",
        ],
        "menu.tooltip.degraded": [
            .th: "NoPeek — log stream หยุดทำงาน กำลังลองใหม่",
            .en: "NoPeek — log stream down, retrying",
        ],
        "menu.tooltip.paused": [
            .th: "NoPeek — pause อยู่ (NORMAL เงียบ; ORG/REMOTE ยังแจ้ง)",
            .en: "NoPeek — paused (NORMAL muted; ORG/REMOTE still alert)",
        ],
        // Shown when notification permission was denied (spec §6) — the banner
        // path does not depend on that permission.
        "menu.notif.denied": [
            .th: "notification ปิด — แบนเนอร์ยังทำงาน",
            .en: "Notifications off — banners still work",
        ],

        // MARK: Banners (spec §6)

        "banner.org": [.th: "🚨 ส่องจากองค์กร: %@ — %@", .en: "🚨 Org is watching: %@ — %@"],
        "banner.remote": [
            .th: "🚨 มีการควบคุมระยะไกล: %@ — %@",
            .en: "🚨 Remote control: %@ — %@",
        ],

        // MARK: About (T17)

        "about.version": [.th: "เวอร์ชัน %@", .en: "Version %@"],
        // Spec §13's first honest limit, one line.
        "about.limits": [
            .th: "Detect + notify เท่านั้น — บล็อก/หยุดไม่ได้",
            .en: "Detect and notify only — it cannot block or stop what it sees",
        ],
        "about.ok": [.th: "OK", .en: "OK"],

        // MARK: Calibration Wizard (T18, spec §6)

        // Window title and one-line purpose. `th` keeps the English jargon
        // name, like the menu item it is opened from.
        "calib.title": [.th: "Calibration Wizard", .en: "Calibration Wizard"],
        "calib.intro": [
            .th: "ทดสอบว่า NoPeek จับสัญญาณบนเครื่องนี้ได้จริง — ทำตาม 3 ขั้นตอน",
            .en: "Check that NoPeek's detectors work on this Mac — follow the three steps",
        ],
        // The three instructions (plan T18 step 5: ⌘⇧5 → Photo Booth → Voice
        // Memos). R16 is why the first one is ⌘⇧5 and not Mission Control.
        "calib.step.screen": [
            .th: "1. กด ⌘⇧5 เพื่อแคปจอ",
            .en: "1. Press ⌘⇧5 to capture the screen",
        ],
        "calib.step.camera": [.th: "2. เปิด Photo Booth", .en: "2. Open Photo Booth"],
        "calib.step.mic": [
            .th: "3. อัดเสียง Voice Memos",
            .en: "3. Record with Voice Memos",
        ],
        // Per-step status. `waiting` is for a step that has not become current
        // yet; the current one shows its countdown; the verdicts name what
        // proved the detector (or why it did not).
        "calib.status.waiting": [.th: "ยังไม่เริ่ม", .en: "not started"],
        "calib.status.current": [
            .th: "⏳ รอสัญญาณ… (เหลือ %@ วินาที)",
            .en: "⏳ waiting for the signal… (%@ s left)",
        ],
        "calib.status.passed": [.th: "✅ %@", .en: "✅ %@"],
        "calib.status.failed": [.th: "❌ %@", .en: "❌ %@"],
        "calib.status.timeout": [.th: "⌛ หมดเวลา", .en: "⌛ timed out"],
        // Result summary (acceptance 12: three verdicts, then the file).
        "calib.summary.passed": [
            .th: "✅ ผ่านครบทั้ง 3 detector",
            .en: "✅ All 3 detectors passed",
        ],
        "calib.summary.incomplete": [
            .th: "⚠️ ผ่าน %@ จาก 3 detector",
            .en: "⚠️ %@ of 3 detectors passed",
        ],
        "calib.saved": [
            .th: "บันทึกผลไว้ที่ calibration.json แล้ว",
            .en: "Result saved to calibration.json",
        ],
        "calib.button.retry": [.th: "ทำใหม่", .en: "Restart"],
        "calib.button.close": [.th: "ปิด", .en: "Close"],

        // MARK: System Checkup (T19, spec §6)

        // Window title; like the wizard's, `th` keeps the English jargon name
        // it is opened by in the menu.
        "checkup.title": [.th: "System Checkup", .en: "System Checkup"],
        "checkup.intro": [
            .th: "สรุปช่องทางที่เครื่องนี้เปิดรับการส่องอยู่ตอนนี้ — เป็นภาพ ณ เวลาที่ตรวจ",
            .en: "The channels this Mac has open right now — a snapshot of the moment it ran",
        ],
        // The loading line, drawn while the probes run off the main thread.
        "checkup.checking": [.th: "กำลังตรวจสอบ…", .en: "Checking…"],
        "checkup.generated": [.th: "ตรวจเมื่อ %@", .en: "Checked %@"],
        "checkup.summary.allOk": [
            .th: "✅ ไม่พบช่องทางที่เปิดอยู่",
            .en: "✅ No open channels found",
        ],
        "checkup.summary.findings": [
            .th: "⚠️ พบ %@ รายการที่ควรดู",
            .en: "⚠️ %@ item(s) need a look",
        ],
        // The four items, in check order.
        "checkup.item.screensharing": [
            .th: "แชร์หน้าจอ (Screen Sharing)",
            .en: "Screen Sharing",
        ],
        "checkup.item.remoteManagement": [
            .th: "Remote Management (ARD)",
            .en: "Remote Management (ARD)",
        ],
        "checkup.item.orgAgents": [
            .th: "agent ขององค์กรที่กำลังรัน",
            .en: "Org agents running",
        ],
        "checkup.item.listeners": [
            .th: "พอร์ตที่เปิดรับจากเครือข่าย",
            .en: "Network listeners",
        ],
        // A sharing service's state. The first placeholder is the daemon's name
        // (`screensharingd` / `ARDAgent`) and the second the pid list, so one
        // line says what was found and on what evidence.
        "checkup.detail.service.off": [
            .th: "ปิดอยู่ — ไม่มี %@ และ service ไม่ได้โหลด",
            .en: "off — no %@ and the service is not loaded",
        ],
        "checkup.detail.service.enabled": [
            .th: "เปิดอยู่ — ยังไม่มีเซสชันที่ใช้งาน",
            .en: "on — no active session yet",
        ],
        "checkup.detail.service.listening": [
            .th: "เปิดรับอยู่ที่พอร์ต %@ — ยังไม่มีเซสชันที่ใช้งาน",
            .en: "listening on port %@ — no active session yet",
        ],
        "checkup.detail.service.active": [
            .th: "กำลังมีเซสชันใช้งานอยู่ (%@ pid %@)",
            .en: "in use right now (%@ pid %@)",
        ],
        "checkup.detail.orgAgents.none": [
            .th: "ไม่พบ agent ขององค์กรที่กำลังรัน",
            .en: "no org agents are running",
        ],
        "checkup.detail.orgAgents.found": [
            .th: "พบ %@ รายการ: %@",
            .en: "%@ found: %@",
        ],
        "checkup.detail.listeners.none": [
            .th: "ไม่มีพอร์ตที่เปิดรับจากเครื่องอื่น",
            .en: "no ports are open to other machines",
        ],
        "checkup.detail.listeners.found": [
            .th: "พบ %@ พอร์ต: %@",
            .en: "%@ open ports: %@",
        ],
        // Tail of a bounded list, e.g. "…, 51653 และอีก 3 รายการ".
        "checkup.list.more": [.th: "และอีก %@ รายการ", .en: "and %@ more"],
        // Severity labels: colour is the fast read, the word is the one that
        // survives VoiceOver and a monochrome screenshot.
        "checkup.severity.ok": [.th: "✅ ปกติ", .en: "✅ ok"],
        "checkup.severity.warn": [.th: "⚠️ ควรดู", .en: "⚠️ worth a look"],
        "checkup.severity.attention": [.th: "🚨 ต้องดู", .en: "🚨 needs attention"],
        // The pinned button copy (plan T19 step 5).
        "checkup.open": [.th: "เปิด System Settings", .en: "Open System Settings"],
        "checkup.button.rerun": [.th: "ตรวจใหม่", .en: "Run again"],
        "checkup.button.close": [.th: "ปิด", .en: "Close"],

        // MARK: Export (T20, spec §6)

        // Window title; like the wizard's and the checkup's, `th` keeps the
        // English jargon name it is opened by in the menu.
        "export.title": [.th: "Export รายงาน", .en: "Export report"],
        "export.intro": [
            .th: "สร้างจาก evidence log ของเครื่องนี้: สรุป (md) + ตาราง (csv) + สำเนา log ดิบ (ndjson)",
            .en: "Built from this Mac's evidence log: summary (md) + table (csv) + raw log copy (ndjson)",
        ],
        // Why the files are not in ~/Downloads: writing there raises macOS's
        // folder-permission prompt, and NoPeek asks for no permission of its
        // own (ruling F4, spec §9/§13).
        "export.location": [
            .th: "ไฟล์เก็บไว้ที่ %@ — ไม่เขียนไป Downloads (เลี่ยง permission prompt) กดเปิดใน Finder เพื่อย้ายไฟล์เอง",
            .en: "Files go to %@ — never Downloads, so macOS shows no folder prompt. Use Reveal in Finder to move them.",
        ],
        "export.preset.7d": [.th: "7 วัน", .en: "7 days"],
        "export.preset.30d": [.th: "30 วัน", .en: "30 days"],
        "export.preset.all": [.th: "ทั้งหมด", .en: "All"],
        "export.running": [.th: "⏳ กำลัง export…", .en: "⏳ Exporting…"],
        "export.done": [.th: "✅ %@ events → 3 ไฟล์", .en: "✅ %@ events → 3 files"],
        "export.empty": [
            .th: "ไม่พบ event ในช่วงนี้ — ยังได้ไฟล์เปล่า 3 ไฟล์",
            .en: "No events in this range — three empty files were still written",
        ],
        "export.failed": [.th: "❌ export ไม่สำเร็จ: %@", .en: "❌ Export failed: %@"],
        "export.savedTo": [.th: "บันทึกไว้ที่ %@", .en: "Saved to %@"],
        "export.reveal": [.th: "เปิดใน Finder", .en: "Reveal in Finder"],
        "export.button.close": [.th: "ปิด", .en: "Close"],

        // MARK: History (T22, spec §6b)

        // Window title; like the wizard's, the checkup's and the export's, `th`
        // keeps the English jargon name it is opened by in the menu.
        "history.title": [.th: "History", .en: "History"],
        "history.intro": [
            .th: "ประวัติการแจ้งเตือนจาก evidence log — ใหม่สุดก่อน อ่านเฉพาะ events ที่ยังอยู่ใน retention",
            .en: "Every event in the evidence log, newest first — only what retention still holds",
        ],
        // The tier filter (spec §6b): one segment per choice. The three
        // single-tier segments are labelled with the pinned tier literals
        // (ORG/REMOTE/NORMAL, the same spelling the log and the menu rows use)
        // and never go through this table; only "ทั้งหมด" is copy.
        "history.tier.all": [.th: "ทั้งหมด", .en: "All"],
        // The `ซ่อน noise` switch (spec §6b) — SYSTEM_NOISE + ALLOWLIST.
        "history.hideNoise": [.th: "ซ่อน noise", .en: "Hide noise"],
        // The four range presets, in segmented order (spec §6b).
        "history.range.today": [.th: "วันนี้", .en: "Today"],
        "history.range.7d": [.th: "7 วัน", .en: "7 days"],
        "history.range.30d": [.th: "30 วัน", .en: "30 days"],
        "history.range.all": [.th: "ทั้งหมด", .en: "All"],
        "history.search.placeholder": [
            .th: "ค้นหา actor / kind / reason",
            .en: "Search actor / kind / reason",
        ],
        // The live count line above the table; the second line replaces it when
        // the filters match nothing at all.
        "history.summary": [.th: "แสดง %@ จาก %@ events", .en: "Showing %@ of %@ events"],
        "history.empty": [
            .th: "ไม่พบ event ที่ตรงกับตัวกรองนี้",
            .en: "No event matches these filters",
        ],
        // The table's column headers — the spec §6b row (เวลา / tier / actor /
        // kind / count), with the count column showing `×N` through the menu
        // row's own key when a throttled burst was folded in.
        "history.col.time": [.th: "เวลา", .en: "Time"],
        "history.col.tier": [.th: "tier", .en: "Tier"],
        "history.col.actor": [.th: "actor", .en: "Actor"],
        "history.col.kind": [.th: "kind", .en: "Kind"],
        "history.col.count": [.th: "count", .en: "Count"],
        // The detail area (spec §6b: reason, rawSummary, pid, actorPath) and
        // the sentence that stands in until a row is selected.
        "history.none.selected": [
            .th: "เลือกแถวเพื่อดูรายละเอียด",
            .en: "Select a row to see its details",
        ],
        "history.detail.reason": [.th: "เหตุผล: %@", .en: "Reason: %@"],
        "history.detail.raw": [.th: "rawSummary: %@", .en: "rawSummary: %@"],
        "history.detail.pid": [.th: "pid: %@", .en: "pid: %@"],
        "history.detail.path": [.th: "actorPath: %@", .en: "actorPath: %@"],
        // What a field with no value reads as (a `nil` rawSummary, pid or path).
        "history.detail.none": [.th: "—", .en: "—"],
        // The row actions (spec §6b) and the footer. `เปิดตำแหน่ง` deliberately
        // reuses the menu's key: reveal means one thing in this app.
        "history.button.trust": [.th: "Trust", .en: "Trust"],
        "history.button.kill": [.th: "Kill…", .en: "Kill…"],
        "history.button.export": [.th: "Export…", .en: "Export…"],
        "history.button.close": [.th: "ปิด", .en: "Close"],

        // MARK: Settings (T23, spec §6c)

        // The menu row (spec §6 spells it `Settings…`) and the window title;
        // like the wizard's and the checkup's, `th` keeps the English jargon
        // name it is opened by.
        "menu.settings": [.th: "Settings…", .en: "Settings…"],
        "settings.title": [.th: "Settings", .en: "Settings"],
        "settings.intro": [
            .th: "แก้ค่า config ของ NoPeek — ค่าที่ผิดช่วงจะไม่ถูกบันทึก",
            .en: "Edit NoPeek's config — a value out of range is never saved",
        ],
        "settings.section.general": [.th: "ทั่วไป", .en: "General"],
        "settings.section.lists": [
            .th: "รายการที่ใช้จับ (เพิ่มจากชุด default)",
            .en: "Detection lists (added to the built-ins)",
        ],
        "settings.section.autokill": [.th: "Auto-kill", .en: "Auto-kill"],
        "settings.language": [.th: "ภาษา", .en: "Language"],
        "settings.language.th": [.th: "ไทย", .en: "Thai"],
        "settings.language.en": [.th: "English", .en: "English"],
        "settings.sound": [.th: "เสียงกับ notification", .en: "Sound with notifications"],
        "settings.bannerOnForRemote": [
            .th: "แบนเนอร์สำหรับ REMOTE",
            .en: "Banner for REMOTE events",
        ],
        "settings.bannerLevel": [.th: "ระดับแบนเนอร์", .en: "Banner level"],
        // The two spec §6 level literals: config values, not translations.
        "settings.level.floating": [.th: "floating", .en: "floating"],
        "settings.level.screenSaver": [.th: "screenSaver", .en: "screenSaver"],
        "settings.cooldown": [
            .th: "cooldown แบนเนอร์ ORG (วินาที, 0–3600)",
            .en: "Org banner cooldown (seconds, 0–3600)",
        ],
        "settings.gap": [
            .th: "เตือนเมื่อไม่เฝ้านาน (นาที, 1–1440)",
            .en: "Gap alert threshold (minutes, 1–1440)",
        ],
        "settings.retention": [
            .th: "เก็บ log (วัน, 1–365)",
            .en: "Keep logs (days, 1–365)",
        ],
        // Spec §6c's purge button, used with the retention that is *saved*.
        "settings.purge": [.th: "Purge now", .en: "Purge now"],
        // Its confirmation: the true count of files the purge removed and the
        // retention it used (both `%@`).
        "settings.purge.done": [
            .th: "🧹 ลบไป %@ ไฟล์ที่เกิน %@ วันแล้ว",
            .en: "🧹 Purged %@ file(s) past %@ days",
        ],
        // The five list areas, labelled by their config key (the file is what
        // a power user will read next to the window).
        "settings.list.orgPatterns": [
            .th: "orgPatterns — pattern องค์กร/RMM (substring ของชื่อหรือ path)",
            .en: "orgPatterns — org/RMM patterns (substring of name or path)",
        ],
        "settings.list.remoteControlExtra": [
            .th: "remoteControlExtra — ชื่อ/pattern ของโปรแกรมควบคุมระยะไกล",
            .en: "remoteControlExtra — remote-control process names/patterns",
        ],
        "settings.list.systemNoiseExtra": [
            .th: "systemNoiseExtra — pattern ของระบบ (log ไว้ ไม่แจ้ง)",
            .en: "systemNoiseExtra — system chatter (logged, never notified)",
        ],
        "settings.list.allowlist": [
            .th: "allowlist — แอปที่ trust (path หรือชื่อ process)",
            .en: "allowlist — trusted actors (path or process name)",
        ],
        "settings.list.autoKillNames": [
            .th: "autoKillNames — ชื่อ process ที่ให้ฆ่า (ต้องใส่ทีละตัว)",
            .en: "autoKillNames — process names auto-kill may kill",
        ],
        "settings.list.hint": [
            .th: "บรรทัดละรายการ — บรรทัดว่างและรายการซ้ำจะถูกตัดออก",
            .en: "One entry per line — blank lines and duplicates are dropped",
        ],
        "settings.autokill.enabled": [.th: "เปิด auto-kill", .en: "Enable auto-kill"],
        "settings.autokill.maxPerHour": [
            .th: "ฆ่าสูงสุดต่อชื่อ (ครั้ง/ชั่วโมง, 1–100)",
            .en: "Max kills per name (per hour, 1–100)",
        ],
        "settings.save": [.th: "บันทึก", .en: "Save"],
        "settings.saved": [.th: "✅ บันทึกแล้ว", .en: "✅ Saved"],
        // Spec §6c: `เปิดไฟล์ config` stays for power users. Its own key
        // because the window spells it as a button, not as the menu's row.
        "settings.openConfig": [.th: "เปิดไฟล์ config", .en: "Open config file"],
        "settings.close": [.th: "ปิด", .en: "Close"],
        // One per validatable field (spec §6c's ranges), plus the one the
        // ranges cannot cover: a field that is not a number at all. Each
        // states its rule, so an inline error is actionable on its own.
        "settings.error.language": [.th: "ต้องเป็น th หรือ en", .en: "Must be th or en"],
        "settings.error.bannerLevel": [
            .th: "ต้องเป็น floating หรือ screenSaver",
            .en: "Must be floating or screenSaver",
        ],
        "settings.error.cooldown": [
            .th: "ต้องอยู่ 0–3600 วินาที",
            .en: "Must be 0–3600 seconds",
        ],
        "settings.error.gap": [
            .th: "ต้องอยู่ 1–1440 นาที",
            .en: "Must be 1–1440 minutes",
        ],
        "settings.error.retention": [
            .th: "ต้องอยู่ 1–365 วัน",
            .en: "Must be 1–365 days",
        ],
        "settings.error.maxPerHour": [
            .th: "ต้องอยู่ 1–100 ครั้ง/ชั่วโมง",
            .en: "Must be 1–100 per hour",
        ],
        "settings.error.number": [.th: "ต้องเป็นตัวเลข", .en: "Must be a number"],

        // MARK: Kill & auto-kill (T21, spec §6d)

        // The two tray-row actions (spec §6: REMOTE/ORG rows carry `Kill`;
        // any row with a path carries `เปิดตำแหน่ง`). Deliberately bare — the
        // row they hang from already names the process.
        "menu.event.kill": [.th: "Kill", .en: "Kill"],
        "menu.event.reveal": [.th: "เปิดตำแหน่ง", .en: "Reveal in Finder"],
        // The confirm dialog (spec §6d): name / location / pid, the Force
        // checkbox, and the corporate-policy warning — verbatim from the spec.
        "kill.title": [.th: "ยืนยันการ kill process?", .en: "Confirm process kill"],
        "kill.detail": [
            .th: "ชื่อ: %@\nตำแหน่ง: %@\npid: %@",
            .en: "Name: %@\nLocation: %@\npid: %@",
        ],
        "kill.force": [
            .th: "Force (SIGKILL) ทันที — ไม่รอ 3 วินาที",
            .en: "Force (SIGKILL) now — skip the 3 s wait",
        ],
        "kill.policy": [
            .th: "การฆ่า agent ขององค์กรอาจขัด policy ของบริษัท",
            .en: "Killing an org agent may violate your company's policy",
        ],
        "kill.button.kill": [.th: "Kill", .en: "Kill"],
        "kill.button.cancel": [.th: "ยกเลิก", .en: "Cancel"],
        "kill.location.unknown": [.th: "ไม่ทราบตำแหน่ง", .en: "location unknown"],
        // Status-line confirmations, one per outcome (T17's pattern: a menu
        // action confirms itself without a notification).
        "kill.done.terminated": [.th: "✅ ส่ง %@ แล้ว: %@", .en: "✅ %@ delivered: %@"],
        "kill.done.escalated": [
            .th: "✅ %@ ไม่ยอมตายด้วย SIGTERM → SIGKILL",
            .en: "✅ %@ survived SIGTERM → SIGKILL sent",
        ],
        "kill.done.refused": [
            .th: "⚠️ pid ถูกใช้ซ้ำแล้ว — ไม่ได้ฆ่า %@",
            .en: "⚠️ pid was reused — %@ not killed",
        ],
        "kill.done.noPermission": [
            .th: "⚠️ ไม่มีสิทธิ์ฆ่า %@ — ต้องสิทธิ์ผู้ดูแล",
            .en: "⚠️ No permission to kill %@ — admin rights needed",
        ],
        "kill.done.noSuchProcess": [.th: "ℹ️ %@ จบไปแล้ว", .en: "ℹ️ %@ is already gone"],
        "kill.done.failed": [
            .th: "❌ kill %@ ไม่สำเร็จ (errno %@)",
            .en: "❌ Could not kill %@ (errno %@)",
        ],
        // The self-guard: NoPeek never kills its own pid.
        "kill.done.self": [
            .th: "⛔ ไม่ฆ่า NoPeek เอง",
            .en: "⛔ Refusing to kill NoPeek itself",
        ],
        // EPERM → the macOS admin prompt, manual only, cancellable (spec §6d).
        "kill.admin.ask.title": [.th: "ต้องสิทธิ์ผู้ดูแล", .en: "Administrator rights needed"],
        "kill.admin.ask.body": [
            .th: "process นี้เป็นของ root — เปิดกล่องรหัส admin ของ macOS เพื่อลองใหม่? (ยกเลิกได้)",
            .en: "This process is root-owned — open the macOS admin prompt to retry? (you can cancel)",
        ],
        "kill.admin.ask.ok": [.th: "เปิดกล่องรหัส admin", .en: "Open admin prompt"],
        "kill.admin.cancelled": [
            .th: "ยกเลิกแล้ว — ไม่ได้ใช้ elevation",
            .en: "Cancelled — elevation not used",
        ],
        "kill.admin.done": [.th: "✅ ใช้สิทธิ์ admin แล้ว: %@", .en: "✅ With admin rights: %@"],
        "kill.admin.failed": [.th: "❌ elevation ไม่สำเร็จ: %@", .en: "❌ Elevation failed: %@"],
        // Auto-kill notifications (spec §6d): the kill, the permission refusal
        // (auto-kill never prompts), and the loop guard's one halt notice.
        "notif.autokill.killed.title": [.th: "🚫 ฆ่า %@ แล้ว", .en: "🚫 Killed %@"],
        "notif.autokill.killed.body": [
            .th: "ส่ง %@ แล้ว (pid %@)",
            .en: "%@ sent (pid %@)",
        ],
        "notif.autokill.escalated.body": [
            .th: "SIGTERM แล้วยังอยู่ → SIGKILL (pid %@)",
            .en: "Survived SIGTERM → SIGKILL (pid %@)",
        ],
        "notif.autokill.denied.title": [
            .th: "kill ไม่ได้ (ต้องสิทธิ์)",
            .en: "Could not kill (needs admin)",
        ],
        "notif.autokill.denied.body": [
            .th: "%@ (pid %@) — auto-kill ไม่เด้ง admin",
            .en: "%@ (pid %@) — auto-kill never prompts for admin",
        ],
        "notif.autokill.halted.title": [
            .th: "auto-kill loop — หยุดฆ่าแล้ว",
            .en: "auto-kill loop — stopped",
        ],
        "notif.autokill.halted.body": [
            .th: "%@ ถูกฆ่า %@ ครั้งในชั่วโมงนี้ — อาจมีตัว respawn เอง",
            .en: "%@ was killed %@ time(s) this hour — something may be respawning it",
        ],

        // MARK: App

        "app.name": [.th: "NoPeek", .en: "NoPeek"],
    ]
}
