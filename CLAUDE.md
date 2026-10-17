# NAS Sync — CLAUDE.md

iOS app that copies videos from the Photos library to the TrueNAS `Videos` SMB share
(`\\192.168.50.164\Videos` → `/mnt/HDD_BKUP_POOL/Videos`), modeled on PhotoSync's Autotransfer.

## Structure

```
NASVideoSync/
  App/        entry point, AppDelegate (registers BG task + location monitor at launch)
  Models/     SyncSettings (UserDefaults); SMB password is in the Keychain
  Services/   SyncEngine (run orchestration), NASClient (AMSMB2), VideoLibrary (PhotoKit export),
              SyncLedger (uploaded asset IDs), BackgroundScheduler, LocationTrigger (CLMonitor)
  Intents/    SyncVideosIntent: Shortcuts action "Transfer New Videos to NAS"
  Views/      ContentView, SettingsView
project.yml   XcodeGen spec (AMSMB2 4.0.3 via SPM) — run `xcodegen generate` after editing
```

## Triggers (iOS gives no always-on background sync)

| Trigger | Mechanism | Window |
|---|---|---|
| When charging | `BGProcessingTask` (external power + network) | minutes; iOS picks the time, usually overnight |
| Arriving home | `CLMonitor` circular region, needs "Always" location | ~30 s after relaunch |
| Shortcut | `SyncVideosIntent` in a Shortcuts personal automation (e.g. join home Wi-Fi) | short |
| Sync Now | foreground + `beginBackgroundTask` | while open, ~30 s after leaving |

Uploads are resumable: 8 MB chunks to `<name>.part`, renamed on completion, so short windows add up.
Remote layout: `<folder>/<yyyy>/<yyyy-MM>/<yyyy-MM-dd_HHmmss>_<original name>`.

## Building

Needs the iOS 26.5 platform installed (Xcode › Settings › Components), then:

```bash
xcodegen generate && open NASVideoSync.xcodeproj
```

Set your Team in Signing & Capabilities and run on the device. Test the charging task from the
debugger: `e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.kamesh.NASVideoSync.charging-sync"]`
