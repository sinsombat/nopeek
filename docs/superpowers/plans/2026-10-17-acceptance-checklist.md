# NoPeek v1 — Acceptance Checklist

Spec §11's 19 items plus the T25 bonus checks. Automated rows were run on **2026-10-19** against
`~/Applications/NoPeek.app` built from `ad3d0ae` (no Swift sources changed by T25; only scripts + docs)
and reinstalled with the new script. Human rows are left for the controller's final round.

**Environment:** macOS 27.0.1 (26A434) · CLT-only toolchain (Swift 6.4) · app built + ad-hoc signed locally.
**Legend:** ✅ = automated PASS with evidence below · ⬜ = human row (still to be done).

## The 19 spec §11 acceptance items

| # | Item | Automated check (command) | Human? | Result |
|---|---|---|---|---|
| 1 | **Capture probe:** ⌘⇧5 while the app runs → NORMAL notification ≤5 s + log event | partial: `grep '"kind":"screen-capture"' ~/Library/Logs/NoPeek/*.ndjson` | yes | ✅ log has live `screen-capture` NORMAL events (`screencapture` + `replayd`) from the prior E2E; ⬜ press ⌘⇧5 now and confirm the notification arrives ≤5 s |
| 2 | **Mission Control spam:** ×10 → 0 notifications, only SYSTEM_NOISE log lines | partial: `grep '"actor":"WindowManager"' ~/Library/Logs/NoPeek/*.ndjson` | yes | ✅ 111 `WindowManager` events are `SYSTEM_NOISE` under the current (default) config; the 32 `ORG` WindowManager lines are from the deliberate acceptance-6 org-test (temporary `orgPatterns` entry) — proof the org rule outranks noise. Snapshot at 12:56: **217 SYSTEM_NOISE** / 97 NORMAL / 72 REMOTE / 42 ORG. ⬜ swipe Mission Control ×10 and confirm silence |
| 3 | **Camera:** open Photo Booth → notification ≤5 s, actor = Photo Booth; graceful close logs `camera-off`, no notification | `open -a "Photo Booth"` + log tail | yes (visual + graceful close) | ✅ automated on-side: `camera-on NORMAL Photo Booth` logged at `12:59:48.603`, ~1 s after `open -a` (see run log A9); ⬜ confirm the notification visually, then close Photo Booth with ⌘Q and confirm no notification |
| 4 | **Mic:** record in Voice Memos → notification ≤5 s | — | yes | ⬜ (mic-on was human-verified on 2026-10-18; re-confirm in the final round) |
| 5 | **Remote:** enable Screen Sharing + `open vnc://localhost` → REMOTE + banner | — | yes (needs admin to enable Screen Sharing) | ⬜ (T13 E2E passed on 2026-10-18; re-confirm) |
| 6 | **ORG test:** put `WindowManager` in `orgPatterns` → ORG + red banner + unmutable | — | yes (Mission Control keystroke + visual) | ⬜ (T13 E2E passed; restore config afterwards) |
| 7 | **Degraded:** kill the log stream → yellow icon ≤10 s, self-recovery ≤30 s + log | `pkill -f '^/usr/bin/log stream'` + log tail | yes (icon colour) | ✅ log side PASS: `monitor-degraded 12:52:08.722` → `monitor-recovered 12:52:09.830` (≈1.1 s, backoff step 1), new child pid; ⬜ confirm the shield turns yellow and back |
| 8 | **Test alert:** menu → all tiers appear | — | yes | ⬜ |
| 9 | **Gap:** `gapAlertThresholdMinutes: 1`, app off 2 min, relaunch → notification + `monitor-gap` + menu row | partial: `grep '"kind":"heartbeat"' …` (cadence proof) | yes (requires Quit + wait) | ✅ heartbeat cadence is real: 9 beats today, ~5 min apart (`12:23:05, 12:28:05, 12:34:36, 12:41:39, 12:46:39, 12:51:39`); T24 already ran the gap E2E (+5:00); ⬜ re-run the 2-min gap in the final round |
| 10 | **Calibration:** wizard completes all 3 detectors, result in `calibration.json` | `cat ~/Library/Application\ Support/NoPeek/calibration.json` | yes (wizard UI) | ✅ file shows all three `passed` (screen `screencapture`, camera `Photo Booth`, mic `mic`, 2026-10-18); ⬜ run the wizard once in the final round |
| 11 | **Checkup:** report matches reality (services / agents / listeners) | `launchctl print system/<label>`, `pgrep`, `netstat -an -p tcp` | yes (compare the window) | ✅ ground truth captured for comparison: Screen Sharing + Remote Management **not loaded** (`Could not find service`), no `screensharingd`/`ARDAgent`, nothing listening on 5900/3283, **4 org agents live** (`GlobalProtect`, `PanGPS`, `CloudflareWARP`, `dcondemand`), 36 listeners — all loopback. ⬜ open the window and compare |
| 12 | **Export:** 7 days → md + csv (+ ndjson) with counts matching the log | `ls ~/Library/Logs/NoPeek/exports`, `wc -l ~/Library/Logs/NoPeek/events-*.ndjson` | yes (click + count match + no prompt) | ✅ destination/write check PASS (see A5): `Exporter.defaultOutputDirectory` = `~/Library/Logs/NoPeek/exports`; write+read probe succeeded with no TCC prompt; `make test`'s live smoke read **425 events** (ORG 42 / REMOTE 72 / NORMAL 97 / SYSTEM_NOISE 212 / ALLOWLIST 2) from the real log. ⬜ export 7 days from the menu, compare the count in the window with `wc -l`, confirm **no folder prompt** |
| 13 | **Resource:** 5 min idle → CPU < 1 %, memory < 100 MB | sampler over 301 s (`ps -o time=,rss=`) | no | ✅ **avg CPU 0.52 %** (every 5-s sample 0.2–0.8 %), **RSS max 49.1 MB** (avg 48.4 MB) — see A4 |
| 14 | **Install:** clean machine `make install` → icon after login; `make uninstall` → no trace except kept log/config | `make install`, `make uninstall`, `launchctl print`, path checks | partial (icon visible, Dock-free) | ✅ round-trip PASS incl. idempotent second uninstall and `--purge` (A2/A3); plist `KeepAlive.SuccessfulExit=false`, mode `644`, launchd `state = running`; ⬜ confirm the shield appears after login and there is no Dock icon |
| 15 | **Kill (user process):** `sleep` → Kill from menu/History → process dies + `process-kill` log | partial: `grep '"kind":"process-kill"' …` | yes (manual click) | ✅ the log carries real kill evidence (`SIGTERM delivered`, loop-guard halt — A13) and the kill path is unit-tested; ⬜ start `sleep 300`, Kill it from the menu with confirm, check the log |
| 16 | **Kill (EPERM→admin):** Kill a root process (launchd pid 1) → admin dialog → **cancel** → logged | partial: log evidence | yes (must cancel the dialog) | ⬜ (T21 E2E verified: pid 1 untouched, EPERM recorded; re-confirm the dialog and cancel) |
| 17 | **Auto-kill + loop guard:** enable + test name → killed ≤5 s + `process-kill`; respawn fast → guard halts after quota | partial: log evidence + unit tests | yes (live respawn scenario) | ✅ prior live E2E lines: two `auto-kill: SIGTERM delivered to sleep` then `auto-kill loop guard halted sleep at 2/hour — no kill` (A13); ⬜ repeat live with `autoKillMaxPerHour` low |
| 18 | **History:** opens, rows match log, filters/search work, REMOTE row has Kill + Reveal | — | yes | ⬜ |
| 19 | **Settings:** retention 30→7 writes config + applies live; out-of-range rejected inline | — | yes | ⬜ (live apply was verified in T23 without relaunch; re-confirm the visual) |

## Bonus checks (T25)

| # | Item | Automated check (command) | Human? | Result |
|---|---|---|---|---|
| B1 | Denied notification permission → menu warning "Notifications off — banners still work" (T3 carry) | — | yes (would change TCC state) | ⬜ |
| B2 | **R8 quit-vs-kill:** `kill -9` → respawn; menu Quit → stays quit until login | `kill -9 $(pgrep -x NoPeek)` + `launchctl print` + log | yes (menu Quit half) | ✅ kill half PASS: pid `27895` → `28891` in ~2 s, `state = running`, new `monitor-started` (21→22). ⬜ menu ▸ Quit NoPeek, wait 30 s, confirm it does **not** come back; relaunch with `make install` |
| B3 | Log-growth read (idle growth is bounded) | `du -sk ~/Library/Logs/NoPeek`, `wc -l` before/after 5 min | no | ✅ 184 KB / 148 lines → 184 KB / 149 lines over 301 s idle = **one heartbeat line per 5 min**, no runaway growth (A4/A6) |
| B4 | Export writes under the logs dir with no folder-permission prompt | `mkdir -p` + write+read probe in `~/Library/Logs/NoPeek/exports`; `grep ~/Downloads` | yes (confirm no prompt on the real click) | ✅ dir exists and is writable from a plain shell with no prompt; no code path writes to `~/Downloads` (only comments/strings); ⬜ click an export and confirm no prompt |
| B5 | Banner click → dismiss + opens the log folder | — | yes | ⬜ (T16/T23 carry; visual only) |
| B6 | Trust / Untrust visual (checkmark in the Trust submenu, Untrust list) | — | yes | ⬜ (T17 carry; visual only) |
| B7 | Degraded icon colour (yellow) | log side: A7 | yes | ✅ log side PASS; ⬜ confirm the yellow shield visually during A7's `pkill` |

## Automated run log (2026-10-19)

All commands run from `/Users/sinsombat/.local/share/opencode/worktree/0ddc51/nopeek-v1`.

### A1 — `make test`

```
$ make test
✔ Test run with 327 tests in 25 suites passed after 1.201 seconds.
```

### A2 — install / uninstall round-trip

```
$ make uninstall
==> stopping gui/503/com.sinsombat.nopeek
==> removing LaunchAgent
    removed: /Users/sinsombat/Library/LaunchAgents/com.sinsombat.nopeek.plist
==> removing app
    removed: /Users/sinsombat/Applications/NoPeek.app
==> keeping logs, config and state (pass --purge to remove them too)
    kept:    /Users/sinsombat/Library/Logs/NoPeek
    kept:    /Users/sinsombat/.config/nopeek
    kept:    /Users/sinsombat/Library/Application Support/NoPeek
==> NoPeek uninstalled — reinstall any time with: make install

after: launchctl not loaded ✓ · plist absent ✓ · app absent ✓ · process gone ✓
       logs kept (184K) ✓ · config kept ✓ · state kept ✓

$ make uninstall          # second run — idempotent
    not loaded — nothing to stop
    not present: …/com.sinsombat.nopeek.plist
    not present: …/NoPeek.app
exit=0

$ make install
==> NoPeek installed and running (pid 38763)
$ launchctl print gui/503/com.sinsombat.nopeek
	state = running
	pid = 38763
$ plutil -extract KeepAlive.SuccessfulExit raw ~/Library/LaunchAgents/com.sinsombat.nopeek.plist
false
$ stat -f '%Sp' ~/Library/LaunchAgents/com.sinsombat.nopeek.plist
-rw-r--r--
```

### A3 — `--purge` branch (backed up, verified removed, restored, reinstalled)

```
$ cp -R ~/Library/Logs/NoPeek …/backup/logs   (+ config, state)
$ ./scripts/uninstall.sh --purge
==> stopping gui/503/com.sinsombat.nopeek
    booted out
==> removing LaunchAgent
    removed: /Users/sinsombat/Library/LaunchAgents/com.sinsombat.nopeek.plist
==> removing app
    removed: /Users/sinsombat/Applications/NoPeek.app
==> --purge: removing logs, config and state
    removed: /Users/sinsombat/Library/Logs/NoPeek
    removed: /Users/sinsombat/.config/nopeek
    removed: /Users/sinsombat/Library/Application Support/NoPeek
gone ✓: all five paths · process: gone ✓
(backup restored: 151 log lines, 15 config keys; make install → pid 39369, state = running)
```

### A4 — resource check (5 min idle)

```
$ python3 …/nopeek-acceptance-resource.py <pid> 300
window_seconds=301.0
avg_cpu_percent=0.522
rss_max_mb=49.1
rss_avg_mb=48.4
(each 5-s sample: CPU 0.20–0.80 %)
```

Memory footnote (checked after the run): the app process sat at 45.9 MB RSS, its `/usr/bin/log stream`
child at 0.9 MB — the <100 MB budget holds whether or not the child is counted.

### A5 — export directory / no-TCC check

```
$ grep -A3 "defaultOutputDirectory: URL" Sources/PWCore/Exporter.swift
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/NoPeek/exports")
$ mkdir -p ~/Library/Logs/NoPeek/exports && printf probe > …/.acceptance-probe
$ cat …/.acceptance-probe    → probe        (write+read OK, no prompt)
$ rm …/.acceptance-probe
$ grep -rn "Downloads" Sources/ | grep -v "never\|not\|no path"   → (only comments/strings)
```

### A6 — log directory `du` + growth (same 301 s window)

```
before: du -sk = 184 KB · events-2026-10-19.ndjson = 148 lines
after : du -sk = 184 KB · events-2026-10-19.ndjson = 149 lines   (+1 heartbeat)
```

### A7 — degraded / recovery

```
$ pkill -f '^/usr/bin/log stream'
new log lines:
12:52:08.722 monitor-degraded nopeek
12:52:09.830 monitor-recovered nopeek
child after: /usr/bin/log stream … (new pid) · app pid 27895 still alive
```

### A8 — R8 kill semantics

```
$ kill -9 27895
new pid=28891 after ~2 s
	state = running
	pid = 28891
monitor-started lines: 21 → 22
```

### A9 — camera on-side (automated partial)

```
$ open -a "Photo Booth"   (log tail 7 s later)
12:59:48.603 camera-on NORMAL Photo Booth | <<<< AVCaptureSession >>>> -[AVCaptureSession_Tundra startRunning]…
(Photo Booth closed with pkill afterwards; no camera-off line — expected, off-events are log-only
 and SIGTERM does not run stopRunning)
```

### A10 — heartbeat cadence (supporting §11-9)

```
9 heartbeat lines today: 12:23:05, 12:28:05, 12:34:36, 12:41:39, 12:46:39, 12:51:39 …
```

### A11 — calibration state

```
calibration.json: screen=screencapture passed · camera=Photo Booth passed · mic=mic passed (2026-10-18)
```

### A12 — checkup ground truth (supporting §11-11)

```
launchctl print system/com.apple.screensharing → Could not find service
launchctl print system/com.apple.RemoteDesktop → Could not find service
pgrep screensharingd/ARDAgent → none · lsof :5900/:3283 → none
org agents now: GlobalProtect, PanGPS, CloudflareWARP, /Library/ManageEngine/UEMS_Agent/bin/dcondemand
non-loopback TCP listeners: none (36 total, all loopback)
```

### A13 — auto-kill loop-guard evidence already in the log (supporting §11-17)

```
10:05:53 sleep | auto-kill: SIGTERM delivered to sleep (pid 27150)
10:05:59 sleep | auto-kill: SIGTERM delivered to sleep (pid 27260)
10:06:05 sleep | auto-kill loop guard halted sleep at 2/hour — no kill
```

## What remains for the controller's human round

- Spec items: **1, 2, 3 (visual/graceful close), 4, 5, 6, 7 (icon), 8, 9, 10 (wizard), 11 (compare window), 12 (click + no prompt), 14 (icon after login), 15, 16, 17, 18, 19** — 18 of 19 items have a human component (only 13 is fully automated).
- Bonus: **B1** (denied warning), **B2** (menu-Quit half), **B4** (no-prompt confirmation), **B5** (banner click), **B6** (Trust/Untrust visual), **B7** (yellow icon) — 6 rows.
- Note for item 14: this was not a *clean* machine (NoPeek had been installed before); the round-trip proves install/uninstall behaviour, not first-boot on virgin hardware.
- Note for item 11: the checkup window must be compared against A12's ground truth; the agents listed there were live at run time and may legitimately change.
