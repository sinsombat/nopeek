# NoPeek

A macOS menu-bar watchdog that tells you when your screen, camera, microphone, or a remote-control tool is being used — and names the app doing it, as far as macOS lets anyone see. Everything stays on your Mac.

[English](#english) · [ภาษาไทย](#ภาษาไทย)

---

# English

## What NoPeek does

NoPeek is a menu-bar shield (no Dock icon, `LSUIElement`). It watches four observation channels and writes every event it sees to a local evidence log; only the meaningful ones raise a notification, and org/remote events raise a red full-screen banner.

| # | Channel | Signal source | Attribution |
|---|---|---|---|
| A | Screen capture (⌘⇧5, purple indicator, third-party capture) | macOS log stream: `com.apple.ScreenCaptureKit`, `replayd`, `ScreenCaptureApprovalUI`, `screencapture`/`screencaptureui`, `tccd` + `kTCCServiceScreenCapture` | client app name from the log line when available; otherwise "unknown capturer" |
| B | Live remote control | process table against the remote-control watchlist (`screensharingd`, `ARDAgent`, `TeamViewer`, `AnyDesk`, …) plus `screensharingd` log lines | process name + path (path only for your own processes) |
| C | Org agent (labeling layer, not a sensor) | every event's actor + path is matched against `orgPatterns` (`/Library/ManageEngine/`, `dcondemand`, `PanGPS`, Tanium, …) | which pattern matched |
| D | Camera | log stream subsystem `com.apple.cameracapture`, `AVCaptureSession startRunning`/`stopRunning` | the app that started the session (Photo Booth, Zoom, …) — direct from the log |
| E | Microphone | `MicWatch` (CoreAudio device state) | none — "the mic is in use" |

**System noise — the macOS 26/27 reality.** Mission Control, Stage Manager and other system UI exercise the screen-capture machinery as their normal operation. On this OS family that chatter comes from `WindowManager` (also `Dock`, `ControlCenter`), which NoPeek classifies as `SYSTEM_NOISE`: it is **logged, never notified, never bannered**. That is deliberate — a purple-indicator firehose would drown the signal. If you insist on being told about it anyway, set `"replaceDefaultLists": true` and define your own `systemNoiseExtra` without `WindowManager` (see the config table).

## The alert model: org-first

The first rule that matches wins, and the org rule sits above everything:

```
1. orgPatterns    → ORG            (can never be muted)
2. systemNoise    → SYSTEM_NOISE   (log only)
3. allowlist      → ALLOWLIST      (log only)
4. remoteControl  → REMOTE
5. everything else → NORMAL
```

| Tier | Notification | Sound | Red banner | Evidence log |
|---|---|---|---|---|
| **ORG** | yes — grouped 60 s/actor, cannot be silenced | always | yes, 60 s/actor cooldown | yes |
| **REMOTE** | yes | always | yes while `bannerOnForRemote` (default) | yes |
| **NORMAL** | yes — throttled (60 s/actor) and muted by Pause | per `sound` | no | yes |
| SYSTEM_NOISE / ALLOWLIST | never | no | no | yes |

The red banner (`NSPanel`, 3 px red border, non-activating, `screenSaver` level by default) shows on every display: *"🚨 Org is watching: \<actor\> — \<kind\>"*. It auto-hides after 6 s; clicking it dismisses it and opens the log folder.

Events arriving inside the 60 s throttle window are folded into one notification with a `×N` count. The log always records every raw event — throttling groups, it never deletes.

## The menu

Click the shield:

- **Status line** — "Watching — nothing detected", or "Screen capture by X (Ns ago)"; after a shutdown gap, "⚠️ Not watching HH:MM–HH:MM".
- **10 latest events** — time · tier · actor — kind. ORG/REMOTE rows open a submenu with **Kill** and **Reveal in Finder**.
- **Trust this app… / Untrust** — manage the allowlist (allowlisted actors are logged but never notified).
- **Test alert** — fires one notification per tier so you can see the design.
- **Calibration Wizard…**, **System Checkup…**, **Export report…**, **History…**, **Settings…** — see below.
- **Pause 30 minutes / 1 hour / Resume** — pauses NORMAL only; ORG and REMOTE always alert.
- **Open log folder / Open config / Reload config**.
- **About**, **Quit NoPeek** (⌘Q) — see [quit semantics](#quit-crash-and-uninstall).

A warning row appears on top if you denied notification permission: *"Notifications off — banners still work"* — the banner path does not need that permission.

The icon has four states: shield (watching), red (being observed), **yellow (log stream down — retrying)**, pause symbol (paused).

## Kill and auto-kill

Killing is a response tool you drive; NoPeek never kills anything on its own unless you explicitly switch auto-kill on.

**Manual kill** (menu row, History row, or the notification's `Kill` button):

1. A confirmation dialog shows the process name, its location (outermost `.app` where resolvable), and the pid. A **Force (SIGKILL)** checkbox is available.
2. The corporate-policy warning is shown every time: killing an org agent may violate your company's policy.
3. `SIGTERM` is sent, NoPeek waits up to 3 s, then escalates to `SIGKILL` if needed.
4. **pid-reuse guard**: immediately before signalling — and again before any elevated retry — the process name is re-checked against the event. A pid that no longer matches is refused, not killed.
5. **EPERM → admin prompt** (manual only): if the process belongs to another user/root, NoPeek offers the standard macOS admin password box (via `osascript … with administrator privileges`) for that one attempt. Cancel and nothing happens; both outcomes are logged.
6. Every attempt is written to the evidence log as a `process-kill` event (signal delivered / EPERM / cancelled / refused / loop-guard stop).

**Auto-kill (opt-in, default off)** — in Settings or the config file:

- `"autoKillEnabled": false` by default. Turning it on kills only processes you listed yourself in `"autoKillNames"` — it is deliberately **not** fed by the watchlist.
- **Your own processes only.** NoPeek runs as you; it cannot auto-kill root-owned processes and will never show an admin prompt from the auto path. Root processes can only be killed manually with the admin prompt above.
- **Loop guard**: at most `"autoKillMaxPerHour"` (default 5) kills *per name per hour*. When the quota is hit, auto-kill stops for that name and notifies: *"auto-kill loop — something may be respawning it"*.
- A killed process may come back — launchd or a system daemon can respawn it. The loop guard is there to stop you fighting the system.

**Caveat, stated plainly:** NoPeek is not an EDR. Killing an org/IT agent on a managed Mac can break your employer's management or violate policy. Confirm dialogs exist for exactly that reason.

## History

`History…` shows the evidence log as a newest-first table: time / tier / actor / kind / count, with:

- tier filter (segmented, including "hide noise"), day range (today / 7 / 30 / all), and a search box (actor/kind/reason);
- a detail pane per row (reason, raw summary, pid, path) with **Trust**, **Kill** (ORG/REMOTE) and **Reveal in Finder** where applicable;
- refresh on open and every 5 s; **Export…** for the current range.

## Settings

`Settings…` edits the config as a validated form and applies it live — no restart:

- **General**: language (ไทย/English), sound, banner on/off for remote, banner level (`floating`/`screenSaver`), org banner cooldown, gap threshold (minutes), retention days (1–365) + **Purge now**.
- **Lists**: `orgPatterns` extra, `remoteControlExtra`, `systemNoiseExtra`, `allowlist` — one entry per line.
- **Auto-kill**: enable, names, max per hour.

Values are validated before writing (out-of-range → inline error, nothing written). Saving reloads and rebuilds the classifier, watchlist, banner cooldown and auto-kill engine immediately. You can still edit `~/.config/nopeek/config.json` by hand — the file is watched and reloaded automatically. `Reload config` in the menu forces it.

## Export

`Export report…` writes a report for **7 days / 30 days / all** as three files with one timestamp:

- `NoPeek-export-YYYYMMDD-HHMM.md` — human summary (range, per-tier counts, full ORG/REMOTE sections);
- `NoPeek-export-YYYYMMDD-HHMM.csv` — one row per event, 9 columns;
- `NoPeek-export-YYYYMMDD-HHMM.ndjson` — verbatim copy of the log lines in range.

They land in `~/Library/Logs/NoPeek/exports/` — deliberately **not** `~/Downloads`, because writing there can trigger a folder-permission (TCC) prompt; this location never does. `Reveal in Finder` opens the folder with the three files selected, and the export itself is recorded as an `export-created` event.

## Calibration Wizard

Runs on first launch (until a machine passes) or from the menu. It walks three steps and checks that each detector really fires on this Mac:

1. Press **⌘⇧5** (screen capture) — Mission Control does not count, it is system noise by design.
2. Open **Photo Booth** (camera).
3. Record with **Voice Memos** (mic).

Each step shows waiting/✅/❌/timed-out, and the result is saved to `~/Library/Application Support/NoPeek/calibration.json`.

## System Checkup

`System Checkup…` takes a read-only snapshot of the observation channels macOS can open: Screen Sharing service (5900), Remote Management/ARD (3283), org agents running right now, and TCP listeners. Findings come with deep links into the relevant System Settings pane. It reports what it sees instead of reading the Screen-Recording permission list — that list would need Full Disk Access, which NoPeek never asks for.

## Config file

`~/.config/nopeek/config.json` — created with defaults on first run, auto-reloaded when changed. Unknown keys are ignored; a wrong-typed key falls back to all defaults and reports the reason (the file is left alone).

| Key | Default | Meaning |
|---|---|---|
| `language` | `"th"` | `"th"` or `"en"` — all UI/notifications |
| `sound` | `true` | sound with NORMAL notifications (ORG/REMOTE always sound) |
| `bannerOnForRemote` | `true` | red banner for REMOTE events |
| `bannerLevel` | `"screenSaver"` | banner window level: `"floating"` or `"screenSaver"` |
| `orgBannerCooldownSeconds` | `60` | banner cooldown per actor (ORG) |
| `logRetentionDays` | `30` | log files older than this are purged at launch |
| `gapAlertThresholdMinutes` | `15` | notify when monitoring was off longer than this |
| `replaceDefaultLists` | `false` | `true` = your lists replace the built-ins instead of merging |
| `orgPatterns` | `[]` | extra org/RMM substrings (name or path) — **checked first, can't be muted** |
| `remoteControlExtra` | `[]` | extra process names for the remote watchlist |
| `systemNoiseExtra` | `[]` | extra log-only noise names |
| `allowlist` | `[]` | actors to log but never notify about |
| `autoKillEnabled` | `false` | master switch for auto-kill |
| `autoKillNames` | `[]` | process names auto-kill may kill — add them one by one |
| `autoKillMaxPerHour` | `5` | auto-kill quota per name per hour (loop guard) |

Built-in defaults (merged unless `replaceDefaultLists`): 23 org patterns (ManageEngine, `dcondemand`, `PanGPS`, GlobalProtect, CloudflareWARP, TeamViewer, AnyDesk, ScreenConnect, ConnectWise, Splashtop, SRService, RustDesk, LogMeIn, LMIGuardianSvc, GoToAssist, AteraAgent, `winagent`, `dwagent`, KaseyaAgent, AgentMon, ZohoAssist, TaniumClient, Tanium) · 12 remote-control names (`screensharingd`, `ARDAgent`, `RemoteManagement`, `remoting_host`, AnyDesk, TeamViewer, ScreenConnect, SRService, Splashtop, `rustdesk`, `dwagent`, `winagent`) · 3 noise names (`WindowManager`, `Dock`, `ControlCenter`). `allowlist` starts empty.

## Where NoPeek's files live

| What | Path |
|---|---|
| App | `~/Applications/NoPeek.app` |
| LaunchAgent | `~/Library/LaunchAgents/com.sinsombat.nopeek.plist` |
| Evidence log | `~/Library/Logs/NoPeek/events-YYYY-MM-DD.ndjson` (+ `exports/`) |
| Config | `~/.config/nopeek/config.json` |
| State (calibration) | `~/Library/Application Support/NoPeek/calibration.json` |

## Quit, crash, and uninstall

The LaunchAgent uses `KeepAlive = { SuccessfulExit = false }`:

- **Quit NoPeek (⌘Q)** exits cleanly (status 0) → it stays quit **until your next login**. It is not respawned.
- **Crash or kill** (`kill -9`, `pkill`) exits abnormally → launchd restarts it (immediately when the app ran longer than `ThrottleInterval`; the 10 s interval is what breaks rapid crash loops). Tampering does not stick.
- Want it stopped permanently? Uninstall it, or remove the LaunchAgent / disable the login item.

```sh
make uninstall                 # stop + remove the app and LaunchAgent; KEEPS logs, config, state
./scripts/uninstall.sh --purge # …and deletes ~/Library/Logs/NoPeek, ~/.config/nopeek,
                               #    ~/Library/Application Support/NoPeek
```

Without `--purge`, a later `make install` picks your history straight back up.

## Honest limits

Detect and notify **only** — NoPeek cannot block, freeze or stop what it sees (except via the user-driven Kill above, which the OS may undo by respawning). Specifically, it cannot see:

- **kext/kernel-level surveillance**, or anything below the userland;
- **server-side viewing** that never touches this Mac's sensors or log stream;
- **external recording devices** (your phone pointing at the screen);
- **anything before NoPeek was installed** — gaps are detected, not back-filled.

More caveats, so nobody is surprised later:

- On this macOS family the purple screen-capture indicator can come from system tools, not just humans; that traffic is `SYSTEM_NOISE` by default (configurable, see above).
- **Camera** detection is log-based (from the capturing app's session start/stop lines) — attribution is direct, but an app killed with `pkill`/`SIGTERM` may never log its `stopRunning`, so you may not get the "off" line. Camera/off events are log-only anyway.
- **Mic** events carry no attribution: they say "the mic is in use", not by whom.
- **Checkup** uses deep links instead of reading the Screen-Recording permission list (that would need Full Disk Access).
- **Kill/auto-kill** are user-directed; auto-kill is user-processes-only, never elevates, and a respawned process will keep coming back until the loop guard stops the fight.
- Killing an org/IT agent may violate corporate policy — every manual kill asks first for this reason.
- Detection depends on macOS log strings, which OS updates can change; the calibration wizard and checkup exist to tell you your channels are still live.

## Troubleshooting

- **No notifications** — check System Settings ▸ Notifications ▸ NoPeek; if denied, the menu shows *"Notifications off — banners still work"*, and org/remote banners keep working regardless.
- **Yellow shield / degraded** — the log-stream child died. NoPeek retries automatically (1→30 s backoff, reset after a stable minute) and logs `monitor-degraded`/`monitor-recovered`. Still yellow? `launchctl print gui/$(id -u)/com.sinsombat.nopeek`, `pgrep -fl "log stream"`, then menu ▸ `Reload config` or re-run `make install`.
- **`ld: warning: search path '…CommandLineTools…'` during builds** — harmless environment noise from a Command Line Tools-only toolchain, not a NoPeek problem (the code itself builds warning-free). The Makefile already compensates for the CLT-only `swift test` plugin quirk.
- **Nothing detected at all** — run the Calibration Wizard and System Checkup; confirm `WindowManager`-style system noise is what you are watching (it is logged-only by design); remember `allowlist` and `replaceDefaultLists` change what is reported.
- **Two notifications for one ⌘⇧5** — known v1 behaviour: both `screencapture` and `replayd` log the capture and the throttle groups per actor. Trust one of them to quiet it.
- **Nothing to kill in a remote row** — Kill only appears for ORG/REMOTE rows whose process still exists; root-owned processes take the manual admin path.

## Build from source

Requirements: **macOS 26+** (developed and tested on macOS 27) and Xcode **Command Line Tools** (`xcode-select --install`). No Homebrew, no third-party dependencies, no Xcode project, no Apple Developer account.

```sh
make test     # full unit suite (swift-testing)
make app      # release build → build/NoPeek.app (ad-hoc signed)
make install  # → ~/Applications/NoPeek.app + LaunchAgent, starts now and at login
make uninstall
```

The app is signed ad-hoc (`codesign -s -`) on your machine. That is why it never quarantines and why it needs no entitlements: the only permission it ever requests is notification delivery, and the app itself asks for that at first launch. No Screen Recording, no Accessibility, no Full Disk Access — and no network traffic at all.

---

# ภาษาไทย

## NoPeek ทำอะไร

NoPeek คือไอคอนโล่บนเมนูบาร์ (ไม่ขึ้นใน Dock, `LSUIElement`) ที่คอยบอกคุณว่าจอ กล้อง ไมค์ หรือเครื่องมือควบคุมระยะไกลถูกใช้อยู่หรือไม่ — พร้อมชื่อแอปที่ทำ ถ้า macOS ยอมให้รู้ ทุกอย่างอยู่ในเครื่องคุณเท่านั้น

NoPeek เฝ้า 4 ช่องทาง และเขียนทุกเหตุการณ์ลง log หลักฐานในเครื่อง มีแค่เหตุการณ์ที่สำคัญเท่านั้นที่เด้ง notification และเหตุการณ์ระดับองค์กร/รีโมทจะเด้งแบนเนอร์แดงเต็มจอ

| # | ช่องทาง | สัญญาณที่จับ | Attribution |
|---|---|---|---|
| A | แคปจอ (⌘⇧5, จุดม่วง, แอปอื่นแคป) | log stream ของ macOS: `com.apple.ScreenCaptureKit`, `replayd`, `ScreenCaptureApprovalUI`, `screencapture`/`screencaptureui`, `tccd` + `kTCCServiceScreenCapture` | ชื่อแอปจากบรรทัด log ถ้ามี; ไม่มี → "ไม่ทราบผู้แคป" |
| B | ควบคุมระยะไกลสด | ตาราง process เทียบ watchlist (`screensharingd`, `ARDAgent`, TeamViewer, AnyDesk, …) + log ของ `screensharingd` | ชื่อ process + path (path ได้เฉพาะ process ของตัวเอง) |
| C | agent องค์กร (ชั้นติดป้าย ไม่ใช่เซนเซอร์) | actor + path ของทุก event ถูกจับคู่กับ `orgPatterns` (`/Library/ManageEngine/`, `dcondemand`, `PanGPS`, Tanium, …) | ระบุว่า match pattern ไหน |
| D | กล้อง | log stream subsystem `com.apple.cameracapture`, `AVCaptureSession startRunning`/`stopRunning` | แอปที่เปิด session (Photo Booth, Zoom, …) — ตรงจาก log |
| E | ไมค์ | `MicWatch` (สถานะ device ผ่าน CoreAudio) | ไม่มี — บอกแค่ "ไมค์ถูกใช้" |

**เสียงรบกวนของระบบ — ความจริงของ macOS 26/27** Mission Control, Stage Manager และ UI ของระบบใช้กลไกแคปจอเป็นงานปกติ บน macOS ชุดนี้เสียงพวกนั้นมาจาก `WindowManager` (รวม `Dock`, `ControlCenter`) ซึ่ง NoPeek จัดเป็น `SYSTEM_NOISE`: **ลง log อย่างเดียว ไม่แจ้ง ไม่เด้งแบนเนอร์** ตั้งใจแบบนี้ เพราะไม่งั้นสัญญาณจริงจะจม ถ้าอยากรู้แม้กระทั่งเสียงนี้จริง ๆ ตั้ง `"replaceDefaultLists": true` แล้วนิยาม `systemNoiseExtra` ของตัวเองโดยไม่ใส่ `WindowManager` (ดูตาราง config)

## โมเดลการแจ้งเตือน: องค์กรมาก่อน

กติกาแรกที่ match ชนะ และกติกาองค์กรอยู่บนสุดเสมอ:

```
1. orgPatterns    → ORG            (ห้าม mute เด็ดขาด)
2. systemNoise    → SYSTEM_NOISE   (ลง log เท่านั้น)
3. allowlist      → ALLOWLIST      (ลง log เท่านั้น)
4. remoteControl  → REMOTE
5. อื่น ๆ          → NORMAL
```

| Tier | Notification | เสียง | แบนเนอร์แดง | Log |
|---|---|---|---|---|
| **ORG** | ✅ จัดกลุ่ม 60 วิ/actor ปิดไม่ได้ | เสมอ | ✅ cooldown 60 วิ/actor | ✅ |
| **REMOTE** | ✅ | เสมอ | ✅ ตาม `bannerOnForRemote` (ค่าเริ่มต้นเปิด) | ✅ |
| **NORMAL** | ✅ throttle 60 วิ/actor, เงียบตอน Pause | ตาม `sound` | ❌ | ✅ |
| SYSTEM_NOISE / ALLOWLIST | ❌ | ❌ | ❌ | ✅ |

แบนเนอร์แดง (`NSPanel` ขอบแดง 3px ไม่แย่ง focus ระดับ `screenSaver` โดยค่าเริ่มต้น) เด้งทุกจอ: *"🚨 ส่องจากองค์กร: \<actor\> — \<kind\>"* ซ่อนเองใน 6 วินาที คลิกที่แบนเนอร์ = ปิด + เปิดโฟลเดอร์ log

เหตุการณ์ที่มาในหน้าต่าง 60 วินาทีจะถูกรวมเป็น notification เดียวพร้อมจำนวน `×N` — log บันทึกทุก event ดิบไม่ตัด การ throttle คือการจัดกลุ่ม ไม่ใช่การลบ

## เมนู

คลิกไอคอนโล่:

- **บรรทัดสถานะ** — "เฝ้าระวังอยู่ — ไม่มีการส่อง" หรือ "กำลังถูกแคปจอโดย X (เมื่อ Ns ที่แล้ว)"; ถ้าเคยมีช่วงแอปปิด จะมี "⚠️ ไม่ได้เฝ้าช่วง HH:MM–HH:MM"
- **10 events ล่าสุด** — เวลา · tier · actor — kind แถว ORG/REMOTE มีเมนูย่อย **Kill** และ **เปิดตำแหน่ง**
- **Trust แอปนี้… / ยกเลิก trust** — จัดการ allowlist (actor ที่ trust จะลง log แต่ไม่แจ้ง)
- **Test alert** — ยิง notification ครบทุก tier ให้ดูตัวอย่าง
- **Calibration Wizard…, System Checkup…, Export รายงาน…, History…, Settings…** — ดูหัวข้อถัดไป
- **Pause 30 นาที / 1 ชั่วโมง / หยุด pause** — pause เฉพาะ NORMAL; ORG/REMOTE แจ้งเสมอ
- **เปิดโฟลเดอร์ log / เปิด config / Reload config**
- **About**, **Quit NoPeek** (⌘Q) — ดู [ความหมายของ Quit](#quit-crash-และ-uninstall)

ถ้าคุณปฏิเสธ notification จะมีบรรทัดเตือนบนสุดของเมนู: *"notification ปิด — แบนเนอร์ยังทำงาน"* (แบนเนอร์ไม่ต้องพึ่ง permission นี้)

ไอคอนมี 4 สถานะ: โล่ (เฝ้าอยู่), แดง (กำลังถูกส่อง), **เหลือง (log stream ตาย — กำลังลองใหม่)**, สัญลักษณ์ pause

## Kill และ auto-kill

การฆ่าเป็นเครื่องมือตอบสนองที่คุณสั่งเอง — NoPeek ไม่ฆ่าอะไรเองจนกว่าคุณจะเปิด auto-kill

**Manual kill** (จากแถวในเมนู, แถวใน History หรือปุ่ม `Kill` บน notification):

1. กล่องยืนยันแสดงชื่อ process, ตำแหน่ง (`.app` ชั้นนอกสุดเท่าที่หาได้) และ pid พร้อม checkbox **Force (SIGKILL)**
2. คำเตือนนโยบายบริษัทขึ้นทุกครั้ง: การฆ่า agent ขององค์กรอาจขัด policy ของบริษัท
3. ส่ง `SIGTERM` รอสูงสุด 3 วินาที แล้วต่อด้วย `SIGKILL` ถ้าจำเป็น
4. **pid-reuse guard**: ก่อนยิงสัญญาณ (และก่อนลองใหม่แบบยกสิทธิ์ทุกครั้ง) ชื่อ process ถูกตรวจซ้ำกับ event — pid ที่ไม่ตรงแล้วจะถูกปฏิเสธ ไม่ยิง
5. **EPERM → ถามรหัส admin** (เฉพาะ manual): ถ้า process เป็นของ user อื่น/root NoPeek จะเสนอกล่องรหัส admin ของ macOS (`osascript … with administrator privileges`) เฉพาะครั้งนั้น กดยกเลิก = ไม่ทำอะไร และบันทึกทั้งสองทาง
6. ทุกครั้งถูกบันทึกเป็น event `process-kill` ใน log (ส่งสัญญาณแล้ว / EPERM / ยกเลิก / ถูกปฏิเสธ / loop guard หยุด)

**Auto-kill (opt-in, ปิดโดยค่าเริ่มต้น)** — ตั้งใน Settings หรือไฟล์ config:

- `"autoKillEnabled": false` โดยค่าเริ่มต้น เปิดแล้วจะฆ่าเฉพาะชื่อที่คุณใส่เองใน `"autoKillNames"` — ตั้งใจไม่ผูกกับ watchlist อัตโนมัติ
- **เฉพาะ process ฝั่ง user ตัวเอง** NoPeek รันด้วยสิทธิ์คุณ มันฆ่า process ของ root ไม่ได้ และจะไม่เด้งกล่อง admin จากทาง auto เด็ดขาด — root ทำได้เฉพาะ manual + admin ด้านบน
- **Loop guard**: จำกัด `"autoKillMaxPerHour"` (ค่าเริ่มต้น 5) ครั้งต่อชื่อต่อชั่วโมง ครบโควตาจะหยุดฆ่าชื่อนั้น + แจ้ง *"auto-kill loop — มีอะไรรีสปอว์นอยู่"*
- process ที่ถูกฆ่าอาจกลับมาถูก launchd หรือ daemon ของระบบ respawn — loop guard มีไว้หยุดการสู้กับระบบแบบนั้น

**พูดตรง ๆ:** NoPeek ไม่ใช่ EDR การฆ่า agent ขององค์กรบนเครื่องที่บริษัทดูแลอาจทำให้ระบบจัดการพังหรือขัดนโยบาย — กล่องยืนยันมีอยู่เพราะเหตุนี้

## History

`History…` แสดง log หลักฐานเป็นตารางใหม่สุดก่อน: เวลา / tier / actor / kind / count พร้อม

- ตัวกรอง tier (segmented รวม "ซ่อน noise"), ช่วงวัน (วันนี้ / 7 / 30 / ทั้งหมด) และช่องค้นหา (actor/kind/reason)
- แผงรายละเอียดต่อแถว (reason, rawSummary, pid, path) พร้อมปุ่ม **Trust**, **Kill** (แถว ORG/REMOTE) และ **เปิดตำแหน่ง** ตามความเหมาะสม
- refresh ตอนเปิดและทุก 5 วินาที; ปุ่ม **Export…** สำหรับช่วงที่เลือก

## Settings

`Settings…` แก้ config ในหน้าฟอร์มที่ validate ให้ และมีผลทันทีโดยไม่ต้องปิดแอป:

- **ทั่วไป**: ภาษา (ไทย/English), เสียง, แบนเนอร์ remote เปิด/ปิด, ระดับแบนเนอร์ (`floating`/`screenSaver`), cooldown แบนเนอร์ org, gap threshold (นาที), retention (1–365 วัน) + **Purge now**
- **Lists**: `orgPatterns` เพิ่มเอง, `remoteControlExtra`, `systemNoiseExtra`, `allowlist` — บรรทัดละรายการ
- **Auto-kill**: เปิด/ปิด, รายชื่อ, สูงสุดต่อชั่วโมง

ค่าถูกตรวจก่อนเขียน (เกินช่วง → error inline ไม่เขียนไฟล์) พอบันทึก ระบบจะ rebuild classifier, watchlist, banner cooldown และ auto-kill engine ทันที ยังแก้ `~/.config/nopeek/config.json` ด้วยมือได้เหมือนเดิม — ไฟล์ถูก watch และ reload เอง หรือกด `Reload config` ในเมนู

## Export

`Export รายงาน…` เขียนรายงาน **7 วัน / 30 วัน / ทั้งหมด** เป็น 3 ไฟล์เวลาเดียวกัน:

- `NoPeek-export-YYYYMMDD-HHMM.md` — สรุปอ่านง่าย (ช่วงเวลา, จำนวนตาม tier, ส่วน ORG/REMOTE ครบ)
- `NoPeek-export-YYYYMMDD-HHMM.csv` — หนึ่งแถวต่อ event, 9 คอลัมน์
- `NoPeek-export-YYYYMMDD-HHMM.ndjson` — สำเนาบรรทัด log ตามต้นฉบับในช่วง

ไฟล์ไปที่ `~/Library/Logs/NoPeek/exports/` — **ไม่ใช่ `~/Downloads`** โดยเจตนา เพราะเขียนที่นั้นอาจเด้งขอสิทธิ์โฟลเดอร์ (TCC) ส่วนตำแหน่งนี้ไม่เด้ง `เปิดใน Finder` จะเปิดโฟลเดอร์พร้อมเลือก 3 ไฟล์ให้ และตัว export เองถูกบันทึกเป็น event `export-created`

## Calibration Wizard

เด้งอัตโนมัติครั้งแรก (จนกว่าเครื่องนี้จะผ่าน) หรือเปิดจากเมนู มี 3 ขั้นตอนตรวจว่า detector ทำงานจริงบนเครื่องนี้:

1. กด **⌘⇧5** (แคปจอ) — ใช้ Mission Control ไม่นับ เพราะเป็น system noise โดยออกแบบ
2. เปิด **Photo Booth** (กล้อง)
3. อัดเสียง **Voice Memos** (ไมค์)

แต่ละขั้นแสดง รอ/✅/❌/หมดเวลา และผลถูกบันทึกที่ `~/Library/Application Support/NoPeek/calibration.json`

## System Checkup

`System Checkup…` ถ่าย snapshot แบบอ่านอย่างเดียวของช่องทางที่ macOS เปิดใช้ได้: บริการ Screen Sharing (5900), Remote Management/ARD (3283), agent องค์กรที่รันอยู่ตอนนั้น และ TCP listeners ผลแต่ละข้อมีลิงก์ไปหน้าตั้งค่าที่เกี่ยวข้องใน System Settings โดยตรง มันรายงานสิ่งที่เห็น แทนการอ่านรายชื่อสิทธิ์ Screen Recording — ซึ่งต้องใช้ Full Disk Access ที่ NoPeek ไม่ขอ

## ไฟล์ config

`~/.config/nopeek/config.json` — สร้างด้วยค่าเริ่มต้นรอบแรก และ reload เองเมื่อไฟล์เปลี่ยน key ที่ไม่รู้จักจะถูกละเว้น; key ผิดชนิดจะถอยไปใช้ค่าเริ่มต้นทั้งชุดพร้อมบอกเหตุผล (ไฟล์ไม่ถูกแตะ)

| Key | ค่าเริ่มต้น | ความหมาย |
|---|---|---|
| `language` | `"th"` | `"th"` หรือ `"en"` — ทั้ง UI และ notification |
| `sound` | `true` | เสียงกับ notification NORMAL (ORG/REMOTE มีเสียงเสมอ) |
| `bannerOnForRemote` | `true` | แบนเนอร์แดงสำหรับ REMOTE |
| `bannerLevel` | `"screenSaver"` | ระดับหน้าต่างแบนเนอร์: `"floating"` หรือ `"screenSaver"` |
| `orgBannerCooldownSeconds` | `60` | cooldown แบนเนอร์ต่อ actor (ORG) |
| `logRetentionDays` | `30` | ไฟล์ log เก่ากว่านี้จะถูก purge ตอนเปิดแอป |
| `gapAlertThresholdMinutes` | `15` | แจ้งเมื่อแอปไม่ได้เฝ้านานกว่านี้ |
| `replaceDefaultLists` | `false` | `true` = list ของคุณแทนที่ default ทั้งชุด (ไม่ union) |
| `orgPatterns` | `[]` | substring องค์กร/RMM เพิ่มเอง (ชื่อหรือ path) — **ตรวจก่อนทุกอย่าง mute ไม่ได้** |
| `remoteControlExtra` | `[]` | ชื่อ process เพิ่มสำหรับ watchlist รีโมท |
| `systemNoiseExtra` | `[]` | ชื่อ noise เพิ่ม (ลง log เท่านั้น) |
| `allowlist` | `[]` | actor ที่ลง log แต่ไม่แจ้ง |
| `autoKillEnabled` | `false` | สวิตช์แม่ของ auto-kill |
| `autoKillNames` | `[]` | ชื่อ process ที่ auto-kill ฆ่าได้ — ต้องใส่เองทีละตัว |
| `autoKillMaxPerHour` | `5` | โควตา auto-kill ต่อชื่อต่อชั่วโมง (loop guard) |

ค่า default ที่ฝังมา (union กับไฟล์คุณ เว้นแต่ `replaceDefaultLists`): org 23 pattern (ManageEngine, `dcondemand`, `PanGPS`, GlobalProtect, CloudflareWARP, TeamViewer, AnyDesk, ScreenConnect, ConnectWise, Splashtop, SRService, RustDesk, LogMeIn, LMIGuardianSvc, GoToAssist, AteraAgent, `winagent`, `dwagent`, KaseyaAgent, AgentMon, ZohoAssist, TaniumClient, Tanium) · รีโมท 12 ชื่อ (`screensharingd`, `ARDAgent`, `RemoteManagement`, `remoting_host`, AnyDesk, TeamViewer, ScreenConnect, SRService, Splashtop, `rustdesk`, `dwagent`, `winagent`) · noise 3 ชื่อ (`WindowManager`, `Dock`, `ControlCenter`) ส่วน `allowlist` เริ่มว่าง

## ไฟล์ของ NoPeek อยู่ที่ไหน

| อะไร | Path |
|---|---|
| แอป | `~/Applications/NoPeek.app` |
| LaunchAgent | `~/Library/LaunchAgents/com.sinsombat.nopeek.plist` |
| Log หลักฐาน | `~/Library/Logs/NoPeek/events-YYYY-MM-DD.ndjson` (+ `exports/`) |
| Config | `~/.config/nopeek/config.json` |
| State (calibration) | `~/Library/Application Support/NoPeek/calibration.json` |

## Quit, crash และ uninstall

LaunchAgent ใช้ `KeepAlive = { SuccessfulExit = false }`:

- **Quit NoPeek (⌘Q)** ออกแบบสะอาด (exit 0) → **หยุดอยู่จนกว่าจะ login ใหม่** ไม่ถูก respawn
- **แครชหรือถูกฆ่า** (`kill -9`, `pkill`) ออกแบบผิดปกติ → launchd ปลุกกลับ (ทันทีถ้าแอปรันมาเกิน `ThrottleInterval` แล้ว; ค่า 10 วินาทีมีไว้ตัดวง crash-loop) ฆ่าทิ้งไม่ให้กลับมาก็ต้องถอนการติดตั้ง
- อยากหยุดถาวร? ถอนการติดตั้ง หรือลบ LaunchAgent / ปิด login item

```sh
make uninstall                 # หยุด + ลบแอปและ LaunchAgent; เก็บ log, config, state
./scripts/uninstall.sh --purge # …ลบ ~/Library/Logs/NoPeek, ~/.config/nopeek,
                               #    ~/Library/Application Support/NoPeek ด้วย
```

ถ้าไม่ `--purge` ครั้งต่อไปที่ `make install` ประวัติเดิมกลับมาทันที

## ข้อจำกัดที่ประกาศไว้

**Detect + notify เท่านั้น** — NoPeek บล็อก/หยุดสิ่งที่เห็นไม่ได้ (ยกเว้น Kill ที่คุณสั่งเอง ซึ่งระบบอาจ respawn กลับ) และจับไม่ได้:

- **kext/ระดับ kernel** ทุกชนิด
- **การดูจากฝั่ง server** ที่ไม่แตะเซนเซอร์หรือ log stream ของเครื่องนี้
- **อุปกรณ์ภายนอก** (มือถือถ่ายหน้าจอคุณ)
- **เหตุการณ์ก่อนติดตั้ง NoPeek** — ช่วงที่หายไปถูกตรวจจับได้ แต่กู้คืนไม่ได้

ข้อจำกัดยิบย่อยเพิ่มเติม:

- บน macOS ชุดนี้ จุดม่วงแคปจออาจมาจากเครื่องมือของระบบ ไม่ใช่คน — traffic นั้นเป็น `SYSTEM_NOISE` โดยค่าเริ่มต้น (ปรับได้ตามหัวข้อด้านบน)
- **กล้อง** ตรวจจับจาก log (บรรทัด start/stop ของแอปที่แคป) attribution ตรง แต่แอปที่ถูก `pkill`/`SIGTERM` อาจไม่ทัน log `stopRunning` จึงอาจไม่มีบรรทัด "ปิด"; event ปิดกล้องเป็น log-only อยู่แล้ว
- **ไมค์** บอกได้แค่ว่า "ถูกใช้" ไม่รู้ว่าใครใช้
- **Checkup** ใช้ deep link แทนการอ่านรายชื่อสิทธิ์ Screen Recording (ต้อง Full Disk Access)
- **Kill/auto-kill** เป็นการตอบสนองที่ผู้ใช้สั่ง; auto-kill เฉพาะ process ฝั่ง user ไม่ยกสิทธิ์ และ process ที่ถูก respawn จะกลับมาจนกว่า loop guard จะหยุดให้
- การฆ่า agent ขององค์กรอาจขัดนโยบายบริษัท — ทุก manual kill จึงถามก่อนด้วยเหตุนี้
- การตรวจจับพึ่งสตริง log ของ macOS ซึ่ง OS update เปลี่ยนได้ — Calibration Wizard และ Checkup มีไว้บอกว่าช่องทางยังทำงานอยู่

## แก้ปัญหาเบื้องต้น

- **ไม่มี notification** — เช็ค System Settings ▸ Notifications ▸ NoPeek; ถ้าปฏิเสธ เมนูจะขึ้น *"notification ปิด — แบนเนอร์ยังทำงาน"* และแบนเนอร์ ORG/REMOTE ยังทำงานอยู่ดี
- **โล่เหลือง / degraded** — child process `log stream` ตาย NoPeek ลองใหม่เอง (backoff 1→30 วิ รีเซ็ตเมื่อรันเสถียรครบหนึ่งนาที) และบันทึก `monitor-degraded`/`monitor-recovered` ถ้าเหลืองค้าง: `launchctl print gui/$(id -u)/com.sinsombat.nopeek`, `pgrep -fl "log stream"` แล้วเมนู ▸ `Reload config` หรือ `make install` ซ้ำ
- **ตอน build เห็น `ld: warning: search path '…CommandLineTools…'`** — เป็นเสียงรบกวนปกติของเครื่องที่ใช้ Command Line Tools เดียว ไม่ใช่ปัญหาของ NoPeek (โค้ดบิลด์ไม่มี warning) Makefile จัดการ quirk ของ `swift test` บน CLT-only ให้แล้ว
- **ไม่จับอะไรเลย** — รัน Calibration Wizard + System Checkup; เช็คว่าสิ่งที่คุณรออยู่นั้นเป็น system noise แบบ `WindowManager` หรือเปล่า (ลง log อย่างเดียวโดยออกแบบ); จำไว้ว่า `allowlist` และ `replaceDefaultLists` เปลี่ยนสิ่งที่รายงาน
- **⌘⇧5 ครั้งเดียวได้ 2 notification** — พฤติกรรมที่รู้อยู่ของ v1: ทั้ง `screencapture` และ `replayd` ลง log แล้ว throttle จัดกลุ่มแยกตาม actor; trust ตัวใดตัวหนึ่งให้เงียบได้
- **แถว remote ไม่มีปุ่ม Kill** — Kill จะโผล่เฉพาะแถว ORG/REMOTE ที่ process ยังอยู่; process ของ root ต้องใช้ทาง manual + admin

## Build จาก source

สิ่งที่ต้องมี: **macOS 26+** (พัฒนาและทดสอบบน macOS 27) และ Xcode **Command Line Tools** (`xcode-select --install`) ไม่ต้องมี Homebrew ไม่มี dependency ภายนอก ไม่มี Xcode project ไม่ต้องมี Apple Developer account

```sh
make test     # unit suite ทั้งชุด (swift-testing)
make app      # release build → build/NoPeek.app (เซ็น ad-hoc)
make install  # → ~/Applications/NoPeek.app + LaunchAgent เริ่มทันทีและทุกครั้งที่ login
make uninstall
```

แอปถูกเซ็น ad-hoc (`codesign -s -`) บนเครื่องคุณ — จึงไม่ถูก quarantine และไม่ต้องใช้ entitlement ใด ๆ สิทธิ์เดียวที่มันขอคือ notification ตอนเปิดครั้งแรก ไม่มี Screen Recording, ไม่มี Accessibility, ไม่มี Full Disk Access — และไม่มีการส่งข้อมูลออกเครือข่ายเลย
