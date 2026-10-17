# NoPeek — Design Spec

วันที่: 2026-10-17 · สถานะ: รอ user review · แบรนด์: **NoPeek** (bundle id `com.sinsombat.nopeek`)

---

## 1. ปัญหา & เป้าหมาย

เครื่อง Mac ที่องค์กรติดตั้ง RMM / remote-management agents (เช่น ManageEngine Endpoint Central/UEMS, VPN, remote-control tools) สามารถถูกสั่ง remote control หรือ screen capture จากฝั่ง IT ได้ macOS มี privacy indicator (จุดม่วง/จุดเขียว/จุดส้ม) แต่

1. indicator ไม่ได้แยกชัดว่า "ใคร" แคปในทุกกรณี และไม่มีการแจ้งเตือนที่จับต้องได้เมื่อผู้ใช้ไม่ได้จ้อง menu bar
2. ไม่มีบันทึกฝั่งผู้ใช้เองว่ามีอะไรมา "ส่อง" เมื่อไหร่
3. เคสจากองค์กรมักไม่ distinguishable จากกิจกรรมปกติของแอปผู้ใช้เอง

**NoPeek** = menu-bar app (LSUIElement, ไม่มีใน Dock) ที่เฝ้าสัญญาณ observation ระดับ userland ทั้งหมด — **แคปจอ, remote-control session, กล้อง, ไมค์** — แล้วแจ้งเตือนทันที + เก็บบันทึกหลักฐาน โดยให้ความสำคัญสูงสุดกับ actor ที่เข้าเกณฑ์ "องค์กร"

### Success criteria

- ตรวจจับได้ภายใน **≤5 วินาที** จาก moment ที่เกิด observation
- เคสระดับองค์กร: แจ้งเตือนแบบ **ห้าม mute เด็ดขาด** (ไม่มี config ไหนปิดได้)
- Mission Control / WindowManager (จุดม่วงประจำของ macOS 27) ต้อง **ไม่ทำ notification** — ลง log เท่านั้น
- **ไม่ต้องขอสิทธิ์ Screen Recording, Accessibility, Full Disk** — ขอแค่ notification
- idle CPU < 1%, memory < 100 MB
- ติดตั้งด้วย `make install` คำสั่งเดียว; `make uninstall` ถอนสะอาด

## 2. Scope & Non-goals

**ทำ:** detect + notify + เก็บ evidence log; จัดชั้น severity; allowlist แอปที่ user trust; UI จัดการผ่าน menu bar

**ไม่ทำ (โดยเจตนา):** บล็อก/หยุดการแคป; ต่อสู้เคส kernel-level/kext; สิ่งที่เกิดฝั่ง server โดยไม่แตะเครื่อง; Windows/Linux port; auto-update; notarization (แจกเป็น source, build เอง); preferences window แยก (config file + เมนู)

## 3. สถาปัตยกรรม

**2 target ใน SwiftPM:**

- **`PWCore`** (library — logic ทั้งหมด ไม่มี UI, เทสต์ได้ด้วย `swift test`)
  - `LogStreamReader` — spawn `/usr/bin/log stream --style ndjson` เป็น child process, อ่าน stdout ทีละบรรทัด, parse JSON, auto-restart แบบ exponential backoff (1s→2s→4s…สูงสุด 30s) เมื่อตาย
  - `ProcessWatch` — poll ทุก 3s: ไล่รายชื่อ process ทั้งระบบ (sysctl `KERN_PROC_ALL`) เทียบกับ watchlist
  - `CameraWatch` — poll ทุก 2s: `AVCaptureDevice` ทุกตัว เช็ค `isInUseByAnotherApplication` (มีใน SDK macOS, verify แล้ว); off-debounce 5s
  - `MicWatch` — poll ทุก 2s: input devices ทุกตัว เช็ค CoreAudio `kAudioDevicePropertyDeviceIsRunningSomewhere`; off-debounce 5s
  - `Classifier` — กติกาจัด tier (§5) → `ClassifiedEvent`
  - `Throttler` — dedup key `(kind, actor, tier)` ภายใน 60s รวมเป็น count
  - `EvidenceLog` — เขียน ndjson ลง `~/Library/Logs/NoPeek/`, rotate รายวัน, purge >30 วันตอน start
  - `ConfigStore` — โหลด/merge default กับ `~/.config/nopeek/config.json`, auto-reload เมื่อไฟล์เปลี่ยน (DispatchSource)
- **`NoPeekApp`** (executable — UI + wiring เท่านั้น)
  - `NSStatusItem` + เมนู, `UNUserNotificationCenter`, `BannerPresenter` (แบนเนอร์แดง), ประกอบทุกอย่าง

**Data flow:**

```
[LogStreamReader] [ProcessWatch 3s] [CameraWatch 2s] [MicWatch 2s]
        └──────────────┬───────────────┘
                       ▼
              RawEvent {ts, source, kind, actor, actorPath, pid, raw}
                       ▼
                  Classifier (กติกา §5)
                       ▼
              ClassifiedEvent {..., tier, reason}
                       ▼
   ┌────────────┬──────────────┬───────────────┬──────────────┐
   ▼            ▼              ▼               ▼              ▼
EvidenceLog  Throttler    TrayModel      Notifier      BannerPresenter
(ทุก event)  (60s dedup)  (10 ล่าสุด)  (UN Notif)    (ORG/REMOTE)
```

**จุดสำคัญ:** NoPeek ไม่เคยแคปจอ/เปิดกล้อง/ไมค์เอง — แค่อ่าน log และ poll property ของระบบ จึงไม่ต้องขอ TCC permission ใดๆ นอกจาก notification

**Error handling:**

- log stream ตาย → restart backoff + ไอคอนเมนูบาร์เป็นเหลือง "degraded" + เขียน event `monitor-degraded`/`monitor-recovered` ลง log
- แอปถูกฆ่า → launchd (KeepAlive, ThrottleInterval 10s) รีสตาร์ท + เขียน `monitor-started` ทุกครั้งที่บูต
- กัน App Nap: `ProcessInfo.beginActivity(.userInitiated)` ตลอดอายุแอป
- parser รับ unknown field ได้เสมอ (forward compatible) — บรรทัดที่ parse ไม่ได้ถูกนับและข้าม ไม่ล้มทั้ง stream

## 4. Detection Matrix

| # | จับอะไร | สัญญาณ (source) | Attribution |
|---|---|---|---|
| A | แคปจอ (ScreenCaptureKit/จุดม่วง) | log stream: subsystem `com.apple.ScreenCaptureKit`; process `replayd`; process `ScreenCaptureApprovalUI`; process `screencapture`/`screencaptureui`; process `tccd` + `kTCCServiceScreenCapture` | ดึงชื่อ client app จากบรรทัด log ถ้ามี; ไม่มี → "ไม่ทราบผู้แคป" |
| B | Remote control สด | `ProcessWatch` เทียบ watchlist (ดู §7) + log stream ของ `screensharingd` | ชื่อ process + path (path ได้เฉพาะ process ของ user ตัวเอง — root-owned agents อาจเห็นแต่ชื่อ) |
| C | องค์กร (labeling layer ไม่ใช่ sensor) | ทุก `RawEvent` เอา `actor` + `actorPath` ไป match `orgPatterns` (§7) | reason ระบุ pattern ที่ match |
| D | กล้อง | `CameraWatch` | best-effort: จับคู่ log `cameracaptured`/`tccd` ±3s ถ้าดึงชื่อได้ |
| E | ไมค์ | `MicWatch` | ไม่มี attribution — แจ้ง "ไมค์ถูกใช้" |

**หมายเหตุความแม่นยำ (จะ validate ตอน implement):** สตริง log จริงของ ScreenCaptureKit/replayd บน macOS 26/27 ต้องทดสอบด้วยการกด ⌘⇧5 ระหว่าง stream (procedure §11) — ถ้าสัญญาณไหนไม่ยิงจริง มี fallback: `tccd` lines + `ProcessWatch` ของ `screencapture`

## 5. Classifier & Severity

**ลำดับกติกา (ตัวแรกที่ match ชนะ) — org มาก่อนทุกอย่างเสมอ:**

```
1. orgPatterns    → tier = ORG
2. systemNoise    → tier = SYSTEM_NOISE   (log เท่านั้น)
3. allowlist      → tier = ALLOWLIST      (log เท่านั้น)
4. remoteControl  → tier = REMOTE
5. อื่นๆ          → tier = NORMAL
```

- กติกาข้อ 1 อยู่บนสุดโดยเจตนา: **ORG ห้ามถูก mute เจ้าไหนกลบ** — แม้ user จะ add actor นั้นเข้า allowlist หรือ systemNoise ก็ตาม
- **Throttle:** key `(kind, actor, tier)` — ภายใน 60s รวมเป็น notification เดียวพร้อม count (เมนูโชว์ ×N); evidence log บันทึกทุก event ดิบไม่ตัด — throttle คือการ "จัดกลุ่ม" ไม่ใช่การ mute
- **ORG ห้าม mute เด็ดขาด:** ไม่มี config/action ใดระงับ ORG และ Pause ไม่กระทบ — ORG ถูกจัดกลุ่มโดย throttle (60s/actor) แต่ไม่เคยถูกปิด
- **แบนเนอร์แดง ORG:** cooldown ต่อ actor 60s (`orgBannerCooldownSeconds`) — event ระหว่าง cooldown ยังได้ notification (จัดกลุ่ม) แต่ไม่เด้งแบนเนอร์ซ้ำ
- **Pause:** ระงับเฉพาะ tier NORMAL — ORG/REMOTE ไม่ถูกระงับ
- ระดับการแจ้งเตือน:

| Tier | Notification | เสียง | แบนเนอร์แดง | Evidence log |
|---|---|---|---|---|
| ORG | ✅ (จัดกลุ่ม 60s/actor, ห้ามปิด) | ✅ | ✅ (cooldown 60s/actor) | ✅ |
| REMOTE | ✅ | ✅ | ✅ (`bannerOnForRemote`, default true) | ✅ |
| NORMAL | ✅ (throttled, หยุดเมื่อ pause) | config `sound` | ❌ | ✅ |
| SYSTEM_NOISE / ALLOWLIST | ❌ | ❌ | ❌ | ✅ |

## 6. Alert UX

**ไอคอนเมนูบาร์ 4 สถานะ:** 🛡️ ปกติ / 🔴 กำลังถูกส่องอยู่ (มี event tier ≠ noise/allowlist ภายใน 10s; ORG ค้างแดง 60s) / 🟡 degraded (log stream ตาย) / ⏸️ paused

**Dropdown เมนู:**

- บรรทัดสถานะ: "เฝ้าระวังอยู่ — ไม่มีการส่อง" หรือ "กำลังถูกแคปจอโดย X (เมื่อ 3s ที่แล้ว)"
- 10 events ล่าสุด: เวลา + tier + actor + kind
- `Trust แอปนี้…` (เลือกจาก actor ที่เพิ่งเห็น) / `ยกเลิก trust`
- `Test alert` (ยิง event ปลอมครบทุก tier ให้ดูว่าแบนเนอร์/เสียงทำงาน)
- `Pause 30 นาที / 1 ชั่วโมง / หยุด pause`
- `เปิดโฟลเดอร์ log` / `เปิด config` / `Reload config`
- `About` / `Quit`

**Notifications (UNUserNotificationCenter):**

- ขออนุญาตครั้งแรกตอนเปิดแอป พร้อมข้อความอธิบาย; ถ้าปฏิเสธ → เมนูขึ้นคำเตือน "notification ปิด — แบนเนอร์ยังทำงาน" (แบนเนอร์ไม่ต้องพึ่ง notification permission)
- ใช้ `threadIdentifier` = `nopeek-<tier>` เพื่อจัดกลุ่ม
- ไม่ใช้ `.timeSensitive` (ต้องมี entitlement — ไม่มีใน ad-hoc build)

**แบนเนอร์แดง (ORG / REMOTE):**

- `NSPanel` แบบ non-activating, ไม่แย่ง focus, ระดับ `screenSaver` (config `bannerLevel`: `floating`|`screenSaver`), แสดงทุกจอ
- กรอบแดง 3px + กล่องข้อความกลางจอ: "🚨 ส่องจากองค์กร: `<actor>` — `<kind>`" + เวลา
- auto-hide 6s; คลิกที่แบนเนอร์ = dismiss + เปิด events log

## 7. Config

ไฟล์: `~/.config/nopeek/config.json` (สร้าง default ให้อัตโนมัติถ้าไม่มี) + auto-reload เมื่อเปลี่ยน

```json
{
  "language": "th",
  "sound": true,
  "bannerOnForRemote": true,
  "bannerLevel": "screenSaver",
  "orgBannerCooldownSeconds": 60,
  "logRetentionDays": 30,
  "replaceDefaultLists": false,
  "orgPatterns": ["/Library/ManageEngine/", "PanGPS", "dcondemand"],
  "remoteControlExtra": [],
  "systemNoiseExtra": [],
  "allowlist": []
}
```

**ค่า default ของแต่ละ list (merge แบบ union กับไฟล์ user):**

- `orgPatterns` (match แบบ substring บนชื่อ process หรือ path — ครอบคลุม RMM/remote/capture-capable agents ที่พบบ่อย):
  `"/Library/ManageEngine/"`, `"dcondemand"`, `"PanGPS"`, `"GlobalProtect"`, `"CloudflareWARP"`, `"TeamViewer"`, `"AnyDesk"`, `"ScreenConnect"`, `"ConnectWise"`, `"Splashtop"`, `"SRService"`, `"RustDesk"`, `"LogMeIn"`, `"LMIGuardianSvc"`, `"GoToAssist"`, `"AteraAgent"`, `"winagent"`, `"dwagent"`, `"KaseyaAgent"`, `"AgentMon"`, `"ZohoAssist"`, `"TaniumClient"`, `"Tanium"`
- `remoteControl` watchlist (process name): `"screensharingd"`, `"ARDAgent"`, `"RemoteManagement"`, `"remoting_host"`, `"AnyDesk"`, `"TeamViewer"`, `"ScreenConnect"`, `"SRService"`, `"Splashtop"`, `"rustdesk"`, `"dwagent"`, `"winagent"`
- `systemNoise`: `"WindowManager"`, `"Dock"`, `"ControlCenter"`
- `allowlist`: ว่าง (user เพิ่มเองผ่านเมนู) — entry เป็น path prefix หรือชื่อ process

**หมายเหตุ:** รายการ default ถูกออกแบบให้ครอบคลุม agent ที่พบบ่อย — เพิ่มรายการได้ผ่าน list ใน config (merge แบบ union); ถ้าต้องการ **แทนที่ default ทั้งชุด** ตั้ง `"replaceDefaultLists": true` แล้ว list ที่ระบุใน config จะใช้แทน default ของ list นั้นทั้งหมด (ใช้สำหรับเคสอย่าง "อยากจับแม้กระทั่ง WindowManager" — ดู §13)

## 8. Evidence Log

- ไฟล์: `~/Library/Logs/NoPeek/events-YYYY-MM-DD.ndjson` (1 event = 1 บรรทัด JSON), เก็บ 30 วัน (`logRetentionDays`)
- บันทึก **ทุก** event ทุก tier + lifecycle events: `monitor-started`, `monitor-degraded`, `monitor-recovered`, `config-reloaded`, `heartbeat` (ทุก 5 นาที — ใช้ตรวจ gap ได้)
- Schema ต่อบรรทัด:

```json
{"ts":"2026-10-17T15:04:05.123+07:00","kind":"screen-capture","actor":"screencapture","actorPath":"/usr/sbin/screencapture","pid":1234,"tier":"NORMAL","reason":"default","count":1,"source":"logstream","rawSummary":"SCStream start request"}
```

- ค่า `reason` ที่เป็นไปได้: `orgPattern:<pattern>` | `system-noise` | `allowlist` | `remote-control` | `default`

## 9. Packaging / Install / Uninstall

```
nopeek/
├── Package.swift
├── Sources/
│   ├── PWCore/          (LogStreamReader, ProcessWatch, CameraWatch, MicWatch,
│   │                     Classifier, Throttler, EvidenceLog, ConfigStore, i18n)
│   └── NoPeekApp/       (main, StatusItemController, MenuBuilder,
│                         NotificationService, BannerPresenter)
├── Tests/PWCoreTests/   (+ Tests/Fixtures/*.ndjson จาก log จริง)
├── scripts/
│   ├── build-app.sh     (swift build -c release → ประกอบ NoPeek.app → ad-hoc codesign)
│   ├── install.sh       (copy → ~/Applications/, เขียน LaunchAgent, bootstrap, launch)
│   └── uninstall.sh     (bootout, ลบ plist + app; log/config เก็บไว้เว้นแต่ --purge)
├── Makefile             (build / test / app / install / uninstall / clean)
├── docs/superpowers/specs/2026-10-17-nopeek-design.md
└── README.md            (EN + TH: ทำอะไร, วิธีใช้, config, ข้อจำกัด, วิธีถอน)
```

- LaunchAgent: `~/Library/LaunchAgents/com.sinsombat.nopeek.plist` — `Program` ชี้ `~/Applications/NoPeek.app/Contents/MacOS/NoPeek`, `RunAtLoad=true`, `KeepAlive=true`, `ThrottleInterval=10`
- Ad-hoc codesign: `codesign --force --deep -s - NoPeek.app` (ไม่ต้อง Developer ID; build เองบนเครื่อง → ไม่มี quarantine)
- **Requirements:** macOS 26+ (ทดสอบจริงบน 27) + Xcode Command Line Tools; ไม่มี dependency จาก brew
- Info.plist: `LSUIElement=true`, `CFBundleIdentifier=com.sinsombat.nopeek`, `NSHumanReadableCopyright`, ไม่ประกาศ usage description ใดๆ (ไม่ใช้ API ที่ต้องขอสิทธิ์)

## 10. i18n

- ข้อความ UI/notification ทั้งหมดผ่าน string table ในโค้ด รองรับ `th` (default) และ `en` — สลับด้วย `"language"` ใน config
- README สองภาษาในไฟล์เดียว

## 11. Testing

**Unit (`swift test`, TDD ระหว่าง implement):**

- ndjson parser: fixture จาก log จริง (§ procedure ข้างล่าง) รวมบรรทัดที่ malformed → ต้องไม่ throw
- classifier: ลำดับกติกา (org บนสุด, noise, allowlist, remote, normal) + เคส org ทับ systemNoise/allowlist
- throttler: count รวมใน 60s, แยก key ถูกต้อง
- config: merge defaults+user, union lists, reload
- retention: purge ตัดไฟล์เกิน N วัน

**Integration (ทำมือตาม procedure, เขียนใน README):**

1. **Capture probe:** กด ⌘⇧5 ระหว่างแอปรัน → ต้องได้ notification NORMAL ≤5s + log event (⌘⇧5 = ใน systemNoise? **ไม่** — เป็น user action ปกติ แจ้ง NORMAL; ใครรำคาญก็ trust `screencaptureui` ได้)
2. **Mission Control spam:** ใช้ Mission Control รัวๆ 10 ครั้ง → **0 notification**, มีแต่ log SYSTEM_NOISE
3. **กล้อง:** เปิด Photo Booth → notification ≤5s; ปิด → ไม่มี spam
4. **ไมค์:** อัด Voice Memos → notification ≤5s
5. **Remote:** เปิด Screen Sharing ใน System Settings แล้วต่อ `vnc://localhost` จากเครื่องเดียวกัน → REMOTE + แบนเนอร์
6. **ORG test:** ใส่ `"WindowManager"` ใน `orgPatterns` (test config) → ต้องได้ ORG + แบนเนอร์แดง + **mute ไม่ได้** (กติกา org มาก่อน systemNoise — เคสนี้พิสูจน์ลำดับ)
7. **Degraded:** `pkill -f "log stream"` → ไอคอนเหลือง ≤10s → ฟื้นเอง ≤30s + log `monitor-recovered`
8. **Test alert:** กดในเมนู → ครบทุก tier
9. **Resource:** เปิด 5 นาที idle → CPU < 1%, memory < 100 MB (Activity Monitor)
10. **Install:** เครื่องสะอาด → `make install` → ไอคอนโผล่หลัง login; `make uninstall` → ไม่มีร่องรอย (ยกเว้น log/config ที่ขอเก็บ)

**Acceptance = ผ่านทั้ง 10 ข้อ + unit test เขียว**

## 12. Risks & Mitigations

| ความเสี่ยง | ผล | ทางรับมือ |
|---|---|---|
| สตริง log เปลี่ยนตาม OS version | detector บางตัวไม่ยิง | parser ทน + fallback (TCC lines + process watch) + integration test ทุกตัวเป็น gate |
| ดึง path ของ root process ไม่ได้ | orgPatterns แบบ path ไม่ match | match ทั้งชื่อ process และ path; ชื่อจาก sysctl อ่านได้เสมอ |
| App Nap หน่วง poller | ตรวจจับช้า | `beginActivity(.userInitiated)` + timer tolerance = 0 |
| User ปฏิเสธ notification | ไม่เห็นการเตือน | แบนเนอร์ทำงานได้โดยไม่ต้องมี permission + เมนูโชว์คำเตือน |
| notification จาก ad-hoc app ไม่โผล่ | ฟีเจอร์หลักพัง | ตรวจเป็นอย่างแรกใน Milestone M0 ก่อนเขียนส่วนอื่น |
| log stream กิน CPU ตอนเหตุการณ์เยอะ | เครื่องช้า | predicate แคบ + จำกัด rawSummary length; วัดใน acceptance ข้อ 9 |

## 13. ข้อจำกัดที่ประกาศไว้ (Honest Limits)

- **Detect + notify เท่านั้น — บล็อก/หยุดไม่ได้**
- ครอบคลุมทุกอย่างที่ผ่าน userland ของ macOS: ScreenCaptureKit/TCC, daemon remote-control, กล้อง, ไมค์
- **จับไม่ได้:** kext/kernel-level surveillance, การดูจากฝั่ง server ที่ไม่แตะเครื่อง, อุปกรณ์ภายนอก, และ gap ที่เกิดก่อนแอปถูกติดตั้ง
- กล้อง/ไมค์แบบ poll บอกได้แค่ "ถูกใช้" — ชื่อผู้ใช้เป็น best-effort
- บน macOS 26/27 สัญญาณ "จุดม่วงจากระบบ" (WindowManager) ถูกจัดเป็น SYSTEM_NOISE โดย default — ถ้า user ต้องการจับแม้กระทั่งสัญญาณนี้ ก็ทำได้ผ่าน config: ตั้ง `replaceDefaultLists: true` แล้วนิยาม `systemNoise` เองโดยไม่ใส่ WindowManager

## 14. Milestones (input สำหรับ implementation plan)

- **M0** — repo skeleton (SwiftPM, Makefile, scripts) + แอปขึ้นเมนูบาร์ + ขอ notification permission + Test alert → **verify OS integration ก่อนเป็นอันดับแรก**
- **M1** — LogStreamReader + ndjson parser + fixtures จาก ⌘⇧5 จริง
- **M2** — Classifier + Throttler + EvidenceLog (unit test ครบ)
- **M3** — Screen capture detection end-to-end (⌘⇧5 → NORMAL ≤5s; Mission Control → เงียบ)
- **M4** — Pollers: process watch + กล้อง + ไมค์ + tier REMOTE
- **M5** — Alert UX ครบ: แบนเนอร์แดง, เมนู actions, allowlist, pause, config reload, i18n
- **M6** — Packaging ขั้นสุดท้าย: uninstall, README EN/TH, retention purge + รัน acceptance ครบ 10 ข้อ
