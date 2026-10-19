# NoPeek v1 — Acceptance Checklist (FINAL)

Run: 2026-10-19 · app built locally (ad-hoc signed) from `main` @ `7643de4` · macOS 27.0.1 (26A434) · CLT-only toolchain
Legend: ✅ = PASS (automated evidence and/or human-confirmed) · △ = PASS-by-log, visual not observable

## The 19 spec §11 acceptance items

| # | Item | Result |
|---|---|---|
| 1 | Capture probe: ⌘⇧5 → NORMAL ≤5 s + log | ✅ human-confirmed ≤5 s + log (`screencapture`/`replayd` events) |
| 2 | Mission Control ×10 → silent, SYSTEM_NOISE log only | ✅ human-confirmed silent (multiple rounds) + log: only `WindowManager` SYSTEM_NOISE |
| 3 | Camera: Photo Booth → notif, actor Photo Booth; ⌘Q close → quiet + `camera-off` logged | ✅ human-confirmed; graceful close logged; off-events log-only (R20) |
| 4 | Mic: Voice Memos → notif ≤5 s | ✅ human-confirmed; actor `mic` by design (CoreAudio has no client identity — spec §4E/§13) |
| 5 | Remote: enable Sharing + vnc → REMOTE + banner | ✅ via ruled fallback: live `sleep` REMOTE E2E (T13) + REMOTE tier/banner paths; live Screen-Sharing enable skipped (needs admin; logic + tier verified repeatedly) |
| 6 | ORG test: WindowManager→orgPatterns → ORG + red banner + unmutable | ✅ human-confirmed banner (all screens, click-to-dismiss, not muted by Pause — 2 controlled rounds) |
| 7 | Degraded: kill log stream → yellow ≤10 s, self-recover ≤30 s + log | ✅ log: degraded→recovered in 1.1–2.0 s (×2 during check); icon colour △ (flash too brief for reliable eyeballing — v2 polish: minimum hold) 
| 8 | Test alert: all tiers | ✅ 3 alerts confirmed (initial "2 of 3" was a local macOS notification-settings state — user fixed; app posts 3 distinct UUIDs; ORG/REMOTE forced sound, NORMAL follows setting, R26) |
| 9 | Gap: threshold 1 min, app off 2 min, relaunch → notif + `monitor-gap` + menu | ✅ T24 live E2E (gap line 2 ms after boot line) + heartbeat cadence logged |
| 10 | Calibration: wizard all 3 detectors + calibration.json | ✅ human-ran wizard: `screencapture` / `Photo Booth` / `mic` all `passed` |
| 11 | Checkup: report matches reality | ✅ report matched ground truth (Screen Sharing/ARD off; 4 org agents attention; only-loopback listeners); deep links corrected to macOS 26/27 pane ids (`Privacy_AudioCapture`, `Services_ScreenSharing`, `Services_ARDService`) + human-verified correct pages |
| 12 | Export: 7 days → md + csv (+ ndjson), counts, no prompt | ✅ human-ran export: files created under `~/Library/Logs/NoPeek/exports`, opened in Finder, no folder prompt (F4) |
| 13 | Resource: 5 min idle → CPU <1 %, mem <100 MB | ✅ automated: avg CPU 0.52 %, RSS max 49.1 MB |
| 14 | Install: `make install` → icon; `make uninstall` → clean | ✅ round-trip + idempotent + `--purge` verified; icon present, Dock-free (`lsappinfo` UIElement). Caveat: round-trip, not a virgin machine |
| 15 | Kill (user process): sleep → menu Kill → dies + log | ✅ human-confirmed dialog + kill; log `process-kill` (SIGTERM delivered) |
| 16 | Kill (EPERM→admin): root process → admin dialog → cancel → logged | ✅ human-confirmed (safe target `syslogd`, dialog CANCELED, nothing killed, refusal logged) |
| 17 | Auto-kill + loop guard | ✅ two live E2Es (killed ≤3.2 s, respawn → guard halted at quota) + unit/regression tests |
| 18 | History: rows match log, filters/search, row actions | ✅ human-confirmed (rows, filters, search; REMOTE row offers Kill / เปิดตำแหน่ง) |
| 19 | Settings: retention 30→7 applies live; out-of-range rejected | ✅ human-confirmed inline error on 9999; save OK; live-apply verified in T23 (watchlist→REMOTE without relaunch) |

**19/19 PASS** (7 & 14 & 5 with the noted methods).

## Bonus checks

| # | Item | Result |
|---|---|---|
| B1 | Denied notification → menu warning | ✅ human-confirmed (toggle off → warning row; on → 3 alerts return) |
| B2 | R8 quit-vs-kill: kill -9 respawns; menu Quit stays quit | ✅ kill half automated (respawn ~2 s); Quit half log-verified (no `monitor-started` between user Quit and deliberate reinstall) |
| B3 | Log growth bounded | ✅ one heartbeat/5 min idle (184 KB → 184 KB over 301 s) |
| B4 | Export writes under logs dir, no folder prompt | ✅ human-confirmed on the real click |
| B5 | Banner click → dismiss + opens log folder | ✅ human-confirmed |
| B6 | Trust / Untrust visual | ✅ human-confirmed (Trust → listed in Untrust; round-tripped) |
| B7 | Degraded icon colour (yellow) | △ same as item 7 (flash 1.1–2.0 s; log-verified; v2 polish candidate) |

## Defects found & fixed during acceptance (all review-clean)

1. **RemoteManagement fleet false positives** — macOS 27 fleet (~21 processes) matched the watchlist via `RemoteManagement` name/path substrings → 21 REMOTE notifications + banners per spawn. Fixed: entry dropped (list = 11), regression test pins zero events; commit `3797854`.
2. **Checkup deep links landed on the wrong pane** — `Privacy_ScreenCapture` anchor doesn't exist on macOS 26/27. Fixed to `Privacy_AudioCapture` + precise Sharing anchors; commit `7643de4`.
3. **"Test alert 2 of 3"** — a local macOS notification-settings state (not an app defect); no code change.
4. **Degraded icon flash too brief to see (1.1–2.0 s self-heal)** — behavior correct; noted as v2 polish (minimum-hold).

## Automated evidence (unchanged from the T25 run)

`make test` 328/25 green · install/uninstall/`--purge` round-trips · resource sampler (0.52 %/49.1 MB) · export-path probe · degraded/recovered log lines · R8 kill respawn · heartbeat cadence · camera on-side · auto-kill/loop-guard log lines.
