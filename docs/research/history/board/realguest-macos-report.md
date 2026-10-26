# Real-guest report, macOS guest (D16, R4), 2026-10-22 (session RG)

VMRunner `main` at `a98fd14` (clean, `.vscode/` already untracked). Mac15,12 (MacBook Air M3, 8 cores, 16 GiB), Darwin 25.6.0.
Wall time 19:35 to 20:56 (1 h 21 min, under the 2 h limit). Everything ran by hand, one app instance at a time.

## Pre-conditions

- `df -g /tmp` at 19:35: `/dev/disk3s5 460 377 61` → **61 GiB free**, at least the 48 GiB allowed for macOS. Proceeded.
- The lowest free space seen during the run was **23 GiB** (`df -k`: 24 498 220 KiB at 20:41:35, near the end of the install). It never fell below the 20 GiB floor.
  A monitor checked every 10 s and would have killed the app under 20 GiB. It never fired.
- Cached restore image in the owner's library, looked at only: `~/Library/Application Support/VMRunner` holds only `Machines/`,
  `Machines.approvals.json` and `.DS_Store`. It has no `Images/` folder and no `.ipsw` (`find -maxdepth 3 -iname '*.ipsw'`: nothing).
  So the image was downloaded through the app's own path into the scratch library.

## How the app was driven

- `swift run vmr build-app` → `build/VMRunner.app` (ad-hoc signed, hardened runtime, `entitlements OK (audio-input, virtualization)`).
- Scratch `/tmp/rgm` (0700): `data/` (`VMRUNNER_DATA_DIR`), `scripts/`, `shots/`, `logs/`.
- Launch: `open -g -n --env VMRUNNER_DATA_DIR=/tmp/rgm/data -a build/VMRunner.app [--args --start rg-macos]`. The pid came from
  `pgrep -n -f .../VMRunner.app/Contents/MacOS/VMRunner`, plus a watchdog per launch that kills only that pid (and only while it
  is still that executable) at its time limit or under 20 GiB free.
- **Headless route to Setup.** No launch argument or defaults key starts setup: `VMRunnerApp.autoStartFromArguments` handles only
  `--start`, and `MachineLookup` refuses a machine that is not set up ("Choose Resume Setup on the machine first"). Setup starts
  only from `VMLibrary.beginSetup`, which the window's New Machine sheet or the **Resume Setup** button calls (`MachineView`).
  Route used: the machine was written by hand as an unfinished setup would leave it:
  `Machines/5E1F0000-0000-4000-8000-00000000A0AC.vm/config.json` =
  `{"guest":"macOS","source":{"latestMac":{}},"isProvisioned":false,"cpuCount":1,"memoryMiB":1024,"diskGiB":16,"maxRuntimeMinutes":20,"networkMode":"nat","audioOutput":false,...}`.
  The window then shows "Setup Incomplete … Resume Setup". The button was pressed with the Accessibility API on the app's own pid
  only: `AXUIElementCreateApplication(pid)` → find the `AXButton` described "Resume Setup" → `AXPress`. `AXIsProcessTrusted()` was
  true for this session. No keystroke, no activation, no other app touched. Progress was read the same way (the window's
  `AXStaticText` title and `AXProgressIndicator`). The same tool pressed the toolbar's **Force Stop** to end each boot.
- Captures: only the app's window, by number (`CGWindowListCopyWindowInfo` filtered on the app's pid, layer 0) →
  `screencapture -x -o -l <n>`.
- CPU and memory: set to 1 / 1024 MiB so that the app's own rule (`config.cpuCount = max(config.cpuCount,
  requirements.minimumSupportedCPUCount)`, the same for memory, in `Provisioner.provisionMac`) raises them to the restore image's
  `VZMacOSConfigurationRequirements` minimum. Result stored by the app: **2 CPUs, 4096 MiB**, within the 4 CPU / 8 GiB cap.

## (1) D16: real macOS install through the app's setup flow: PASS (on the second attempt)

### Download (app's own path: `.latestMac` → `VZMacOSRestoreImage.latestSupported` → `ImageStore.fetch`)

- Resume Setup pressed 19:38:10 → "Downloading UniversalMac_26.6.2_25G83_Restore.ipsw".
- File: **19 772 231 540 bytes (18.4 GiB)**, done 20:32:58: **about 54 min 48 s, about 6.0 MB/s on average** (4.7 MB/s in the first
  10 min, about 7 MB/s later). "Verifying" (SHA-256 from ipsw.me) took about 10 s (20:32:58 to 20:33:08). Cached at
  `Images/885503b7…dd51c95/UniversalMac_26.6.2_25G83_Restore.ipsw` (the directory is the checksum, so ipsw.me had it).
- While it ran, URLSession's own temporary file was **outside the scratch data directory**:
  `lsof -p <app>` → `/private/var/folders/_l/…/T/CFNetworkDownload_rApzWH.tmp` (548 MB at 19:39, 2.59 GB at 19:47). It was
  moved into `Images/.partial/<UUID>` at the end (the same inode, 375888847, later became the cached file). See defects.

### Install attempt 1 (16 GiB disk, the New Machine sheet's minimum): FAIL, from the guest side

- 20:33:08 "Installing macOS 26", 20:33:34 → window: "Setup failed — An error occurred during installation. Installation
  failed." App log: `[com.example.VMRunner:machine] Setup failed (VZErrorDomain 10007): <private>`. 10007 is the framework's
  generic installation failure. The install ran 26 s, which fits a disk that is too small. 16 GiB is the
  lower end of `EditorLimits.newDiskGiB` (16...2048) and cannot hold macOS 26.6.2 (the 40 GiB install below uses 21 GB).
- **Clone observed** (3 s listing of the images directory, `stat -f "%i %z %b"`):
  ```
  20:33:05 free_kib=50377776  (Verifying)
  20:33:08 free_kib=50351888  Installing macOS 26
    376391397 19772231540 38617640 …/.install-4E554856-8E0A-4BF2-8338-6DD2E2E3238A-UniversalMac_26.6.2_25G83_Restore.ipsw
    375888847 19772231540 38634880 …/UniversalMac_26.6.2_25G83_Restore.ipsw
  20:33:37 free_kib=50341716  (failed)
    375888847 19772231540 38634880 …/UniversalMac_26.6.2_25G83_Restore.ipsw      ← no .install-* left
  ```
  The clone has its own inode and the full size, but making it cost about 26 MB of free space for an 18.4 GiB file: APFS
  shares the blocks. (`ls` "total" and `du` count both files in full, because they do not see shared extents.) The
  installer read the clone: the framework's `DiskImages2` log shows the disk and the restore image opened after the clone
  appeared. The `defer` in `provisionMac` removed the clone after the failure, and the cache file stayed, as the code intends
  (`discardCachedRestoreImage` runs only on success).

### Install attempt 2 (40 GiB sparse disk): PASS

- I quit the app, deleted only the bundle's `Disk.img`, and set `diskGiB` to 40 (stepper multiple of 8; chosen as the first
  size that should comfortably fit after 16 failed, with only one retry left in the time budget). Relaunched and pressed
  Resume Setup at 20:37:16.
- "Looking up the latest" (20:37:16) → "Checking UniversalMac_…ipsw" (cached file re-verified, 20:37:20 to 20:37:29, about 9 s) →
  "Installing macOS 26" 20:37:29 → progress 16 %, 38 %, 53 %, 69 %, 78 % (held 1 min), 90 % (held 1 min) → finished
  about 20:41:38. **Install time about 4 min 10 s.**
- Clone again: `.install-0207A3B2-B00C-46CE-9FB4-BB7032FF7BBD-UniversalMac_26.6.2_25G83_Restore.ipsw`, inode 376418189
  (the cache file's is 375888847), present from 20:37:29 to 20:41:35. At 20:41:38 the images directory was **empty**: no
  `.install-*` left, and the cached image itself had been deleted by `discardCachedRestoreImage` (`keepsRestoreImages` unset).
  Free space went from 24.5 GiB to 44.7 GiB.
- Result in `config.json`: `isProvisioned: true`, `guestVersion: "26.6.2 (25G83)"`, `cpuCount 2`, `memoryMiB 4096`, `diskGiB 40`.
  Bundle: `Disk.img` 42 949 672 960 bytes nominal, **21 GB allocated** (`ls -s`: 44 828 384 blocks); `AuxiliaryStorage`
  33 579 164; `HardwareModel` 132; `MachineIdentifier` 60.

Verdict **PASS** for the app's macOS setup (download, verify, clone, install, cleanup of the clone on failure and on success).
Not observed: a cancel during download or install, two setups sharing one cached image at once, a user-picked IPSW (read in
place, no clone).

## (2) R4: fresh identity per start on a macOS guest: PASS

The machine was set disposable with a fresh identity by editing `config.json` while the app was not running
(`"ephemeral": true, "freshIdentityPerStart": true`). It was started with `--start rg-macos`, read 12 s after launch, captured at
45, 90, 150 and 210 s, and stopped with the toolbar's Force Stop (AXPress). The machine's own `MachineIdentifier` was the same
throughout: sha256 `7f09ecca…473a13`, ECID `0x137ced2723fd9d24`.

| Start | Mode | `MachineIdentifier.ephemeral` (sha256 / ECID) | `macAddress` the app stored | Window |
|---|---|---|---|---|
| eph1 20:42:25 | disposable, fresh | `159b44b5…3a823a8` / `0xecffc9fff75ef8bb` | `5e:b2:03:08:23:24` | 45 s: Setup Assistant welcome ("ciao", "Continua"); 210 s: "Sprache" language list |
| eph2 20:46:27 | disposable, fresh | `8c4e5d9b…796ca3f9` / `0xd7791a9feda821a9` | `f2:c8:9c:45:8d:ee` | same: welcome at 45 s, language list at 210 s |
| norm 20:50:26 | not disposable | none (uses `MachineIdentifier`, `0x137ced…`) | `f2:c8:9c:45:8d:ee` (kept) | language list at 210 s |

- Each disposable start made `Disk.ephemeral.img`, `AuxiliaryStorage.ephemeral` and a 68-byte `MachineIdentifier.ephemeral`
  (a `VZMacMachineIdentifier` data representation, a bplist with key `ECID`). The identifier and the MAC differed between the
  two starts and from the machine's own. Force Stop removed all three files (bundle listing after the stop: none).
- **A macOS guest with a different machine identifier boots**: both disposable starts reached the Setup Assistant on the
  framework's normal boot, with the identifier written that same start, and the non-disposable start also boots. The
  review's worry is not borne out here. Caveat: this guest had never finished the Setup Assistant, so nothing tied to the
  identifier (iCloud, FileVault, activation) existed yet. Not observed: a guest past the Setup Assistant (a user account,
  Apple ID, keychain), which is where a changed ECID could matter.
- Boot time to the first Setup Assistant screen: under 45 s after launch in all three starts (the first capture was at 45 s).
  The display log line came about 2 s after launch (`Starting display 1292×1200 px` at 20:42:23 for eph1).
- `hasBooted` stayed false through the two disposable starts and became true on the non-disposable start, as
  `recordFirstBoot` intends.

Verdict **PASS**.

## (3) Timings

| Phase | Time |
|---|---|
| App build (`vmr build-app`, already built) | 6 s |
| Download, 19 772 231 540 B | 19:38:10 to 20:32:58, about 54 min 48 s (~6.0 MB/s average) |
| Verify after download / re-check on resume | ~10 s / ~9 s |
| Install attempt 1 (16 GiB) | 26 s, then failure |
| Install attempt 2 (40 GiB) | 20:37:29 to ~20:41:38, about 4 min 10 s |
| First boot to the Setup Assistant | under 45 s (eph1, eph2, norm) |
| Each guest run | about 3 min 50 s (well under the 20 min limit; the app's own `maxRuntimeMinutes = 20` countdown showed 16:23 at the end) |

## Defects and observations

1. **The 16 GiB minimum of the New Machine sheet cannot hold a macOS guest.** Installing macOS 26.6.2 into 16 GiB failed with
   `VZErrorDomain 10007` after 26 s, after an 18.4 GiB download. The installed system uses 21 GB. `EditorLimits.newDiskGiB =
   16...2048` (`Sources/VMRunner/Model/EditorLimits.swift`) applies to both guests, and `NewMachineSheet` uses it as is. Suggest
   a macOS floor (e.g. 32 or 40 GiB) in the sheet and the editor, or a check before installing. The error the user sees
   ("Installation failed") does not say why.
2. **The download's temporary file is outside `VMRUNNER_DATA_DIR`.** While it runs, URLSession writes
   `$TMPDIR/CFNetworkDownload_*.tmp` (18.4 GiB here) and moves it into `Images/.partial` only at the end
   (`FileDownloader`, `session.downloadTask`). CONTRIBUTING says the setting keeps "everything it stores" in the folder. A
   download killed midway leaves the file in `$TMPDIR`. Five older 20 000-byte `CFNetworkDownload_*.tmp` files from Oct 22,
   01:41 to 09:53 sit there now (not this session's). Either document it, or use a session whose downloads go to the
   work directory (a data task streaming to a file).
3. **The owner's preferences were changed by a scratch run.** `~/Library/Preferences/com.example.VMRunner.plist` has mtime 20:50
   (it was 12:51 per the earlier report). The key `NSSplitView Subview Frames SwiftUI.ModifiedContent<…ContentView…>` now reads
   `0, 0, 314, 943, YES, NO`, which marks the sidebar as collapsed. During eph2, between two captures, the window became active,
   was resized and its sidebar was hidden. None of this session's tools sends anything that would do that (only `AXPress` on
   Resume Setup and Force Stop). It carried into the next launch ("Show Sidebar"), and the owner's next normal launch may open
   with the sidebar hidden. CONTRIBUTING already says split-view autosave escapes the override domain. This is that limitation
   in practice. I did not edit the owner's preferences. The owner may want to re-show the sidebar, or
   `defaults delete com.example.VMRunner "NSSplitView Subview Frames SwiftUI.ModifiedContent<…>"`. Fix: give the split view an
   autosave name in the override domain, or none, when `PreferencesDomain.isSeparate`.
4. **The last disposable MAC sticks after "disposable" is turned off.** `VMController.start` writes the fresh MAC into the
   stored config (`library.update(config)`), so the non-disposable start used `f2:c8:9c:45:8d:ee`, the address of the last
   disposable run. That links the persistent machine to its last "unlinkable" run. Low severity. Possible fix: keep the
   disposable run's MAC in the launch only, or restore the previous one at stop.
5. Observation, not a defect: `AppKit` saved state goes to `$TMPDIR/com.example.VMRunner.savedState/` even with restoration
   disabled. It is the same folder the earlier session's run created at 18:58. Removed at cleanup.

## Not run / not observed

- Completing the Setup Assistant (not needed, and not possible without input to the guest).
- Cancel and resume of a download or install. Two setups sharing a cache. Suspend of a macOS guest.
- The `.install-*` clone being read was inferred from the order of events (the clone appeared, then the installer opened the
  image). The installer's reads were not traced per file (`fs_usage` needs root).

## Cleaned

- Removed `/tmp/rgm`, which held: the machine bundle (`config.json`, 40 GiB sparse `Disk.img` with 21 GB used, `AuxiliaryStorage`,
  `HardwareModel`, `MachineIdentifier`), `Machines.approvals.json`, `Images/` (empty after the install, plus `.partial/`),
  the helper tools (`ax`, `winshot` and their sources), the scripts (`launch.sh`, `monitor.sh`, `imgwatch.sh`,
  `bootrun.sh`), 14 window captures, the logs (build, `log stream`, monitors, image watch, pid files).
- Removed `$TMPDIR/com.example.VMRunner.savedState/` (AppKit state the launches rewrote). The download's `CFNetworkDownload_rApzWH.tmp`
  was already gone (the app moved it). No other file was created outside the scratch.
- Stopped: 5 app processes (pids 3346, 4365, 10582, 15063, 15584, each ended by Force Stop or idle, then `kill`), their
  watchdogs, the image watcher, `log stream` (3341). `ps` afterwards: no VMRunner, helper, `log stream` or script process.
- `ls /tmp`: no `rgm`. `df -g /tmp`: **64 GiB free** (61 at the start). No disk image was attached.
- Not touched: `~/Library/Application Support/VMRunner` (looked at only). The owner's preferences plist was changed by the
  app itself (defect 3) and was left as it is. Repository: HEAD `a98fd14`, `git status` shows only the existing `.vscode/`. Kept as
  allowed: `build/VMRunner.app`, `.build/`.
