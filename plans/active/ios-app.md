# iOS App (MacParakeet for iPhone) Implementation Plan

> Status: **PROPOSAL** - 2026-10-16

## Overview

Ship an iPhone companion to MacParakeet scoped to the **WisprFlow feature set**:
dictate into any app via a minimal custom keyboard, with Parakeet running locally
on the Neural Engine, the same clean pipeline (custom words, snippets, filler
removal), dictation history, and opt-in iCloud sync of vocabulary, snippets,
settings, and history with the Mac app.

The keyboard is a **launcher, not a real keyboard**: a mic button, globe key, and
a few utility keys. Users switch back to their normal keyboard (globe) to type.

### In scope

1. iOS app target sharing `MacParakeetCore` (Parakeet STT, pipeline, GRDB repos)
2. Minimal keyboard extension that triggers dictation and inserts the result
3. Background dictation session in the host app (WisprFlow-style "open app → tap Back")
4. History, custom words, snippets, processing mode, settings screens
5. Opt-in iCloud sync (CloudKit) between Mac and iOS
6. Optional: cloud LLM refinement reusing existing providers (already exists in Core)

### Out of scope

- File transcription, YouTube, FFmpeg, video player, diarization, library view
- Local CLI LLM providers (`LocalCLIExecutor` — no `Process` on iOS)
- Non-Parakeet models
- A full typing keyboard (swipe, autocorrect, layouts)
- Shortcut/Action Button triggers (possible later via `AudioRecordingIntent`)
- iPad-specific layout, Sparkle, LemonSqueezy licensing

### Invariants (must not change)

- Mac app behavior and `swift test` suite stay green throughout
- Audio never leaves the device; sync carries text only, never audio
- Sync is **off by default**; with it off, the iOS app makes no network calls
  except model download (and telemetry, opt-out as on Mac)
- `MacParakeetCore` stays UI-free (no UIKit/SwiftUI imports)

## Design Decisions

### D1. Keyboard ↔ app architecture

The model can't run in the keyboard extension (~50–70 MB memory cap; Parakeet
needs model weights + ~66 MB working memory). All audio + STT runs in the host
app, kept alive by the `audio` background mode.

```
Keyboard extension                         Host app (background audio session)
──────────────────                         ───────────────────────────────────
[mic] tap ──► session alive? ──no──► open app via URL ──► start AVAudioSession,
                │                                          user taps "◀ Back"
                yes
                ▼
  Darwin notify "start" ───────────────────────────────► DictationService.startRecording
  [stop] tap → Darwin notify "stop" ───────────────────► stopRecording → STT → pipeline
                                                         write result to App Group
  ◄──────────────────────────────── Darwin notify "result-ready"
  read App Group → textDocumentProxy.insertText(text)
```

- **IPC:** `CFNotificationCenterGetDarwinNotifyCenter` for signals (no payload),
  App Group container (`group.com.macparakeet`) for payloads: a small JSON
  "session file" with `{sessionID, state, heartbeatAt, lastResult{id,text}}`.
- **Session liveness:** host app writes a heartbeat every ~2 s while the audio
  session is active. Keyboard treats heartbeat older than ~5 s as dead → reopen app.
- **Session timeout:** host app ends the idle audio session after a configurable
  window (default 5 min, WisprFlow-like) to save battery; shows a Live Activity
  while the session is active so the user knows the mic session is held.
- **Result de-dup:** keyboard tracks last inserted result ID so a re-fired
  notification never double-inserts.

### D2. Opening the host app from the keyboard

No public API exists for keyboards. Use the responder-chain approach
(walk `next` responders to `UIApplication` and call `open(_:)`) as WisprFlow and
similar apps do. Isolate it in one file (`AppLauncher.swift`) behind a protocol
so it can be swapped if iOS breaks it. Fallback UI: "Open MacParakeet" text
with instructions if the open fails.

### D3. Full Access

The keyboard requires `RequestsOpenAccess = YES` (App Group access). Onboarding
explains why before the user hits Apple's warning. Without Full Access the
keyboard shows a single "Enable Full Access in Settings" prompt.

### D4. Core platform split

Keep one `MacParakeetCore` target, guard macOS-only files with `#if os(macOS)`
(cheaper than a new target, keeps imports unchanged). Files:

| File | Action |
|------|--------|
| `Services/AccessibilityService.swift` | `#if os(macOS)` |
| `Services/ClipboardService.swift` | `#if os(macOS)` |
| `Services/PermissionService.swift` | split: mic permission shared, AX macOS-only |
| `Services/LaunchAtLoginService.swift` | `#if os(macOS)` |
| `Services/LocalCLIExecutor.swift`, `LocalCLILLMClient.swift` | `#if os(macOS)`; `RoutingLLMClient` skips local providers on iOS |
| `Services/YouTubeDownloader.swift`, `VideoStreamService.swift`, `ThumbnailCacheService.swift`, `BinaryBootstrap.swift` | `#if os(macOS)` |
| `Services/ExportService.swift` | `#if os(macOS)` (no export on iOS v1) |
| `Audio/AudioDeviceManager.swift` | `#if os(macOS)` |
| `Audio/AudioRecorder.swift` | abstract device selection; iOS path configures `AVAudioSession` (`.playAndRecord`/`.record`, `.measurement`, `allowBluetooth`) and handles interruptions + route changes |
| `Audio/AudioFileConverter.swift` | `#if os(macOS)` (FFmpeg) |
| `STT/FnKeyStateMachine.swift`, `STT/HotkeyTrigger.swift`, `STT/KeyCodeNames.swift` | `#if os(macOS)` |
| `Services/CrashReporter.swift` | verify Mach APIs compile on iOS; else guard |
| `Licensing/*` | keep compiling; iOS passes `entitlements: nil` |

`DictationService` already takes protocol dependencies (`AudioProcessorProtocol`,
`STTClientProtocol`, repos) and needs no change. ViewModels: guard AppKit usage
in `DictationHistoryViewModel` and `FeedbackViewModel`.

`Package.swift`: add `.iOS(.v18)` to `platforms`. The Mac-only executable
targets and Sparkle remain macOS (use `.when(platforms: [.macOS])` on the
Sparkle dependency).

### D5. Project structure

SPM can't build an iOS app with an app extension, so add an Xcode project for
iOS only (Mac build scripts unchanged):

```
iOS/
├── MacParakeetiOS.xcodeproj       # references local package ../
├── App/                            # SwiftUI app (host)
│   ├── MacParakeetiOSApp.swift
│   ├── DictationSessionController.swift   # background audio session, IPC, heartbeat
│   ├── Views/ (Onboarding, Home, History, Vocabulary, Settings)
│   └── Info.plist  (UIBackgroundModes: audio; URL scheme macparakeet://)
├── Keyboard/                       # keyboard extension (no Core STT import)
│   ├── KeyboardViewController.swift
│   ├── KeyboardView.swift          # SwiftUI: mic, globe, space, delete, return
│   └── AppLauncher.swift
└── Shared/                         # compiled into both targets
    ├── SessionIPC.swift            # Darwin notify names + App Group session file
    └── AppGroup.swift
```

The keyboard links **only** `Shared/`, never `MacParakeetCore` (keeps it far
under the memory cap).

Database lives in the App Group container so the keyboard *could* read recent
history later; v1 keyboard only uses the session file.

### D6. Model download

FluidAudio downloads Parakeet v3 into the app container on first launch
(onboarding step, Wi-Fi recommended, progress UI, resumable). Check free space
before download. Exclude model dir from iCloud backup (`isExcludedFromBackup`).

### D7. iCloud sync

- **Engine:** `CKSyncEngine` (iOS 17 / macOS 14), private database, one custom zone.
- **Synced record types:** `CustomWord`, `TextSnippet`, `Dictation` (text +
  metadata only; no audio), settings (processing mode, etc.).
- **IDs:** existing UUID primary keys map directly to `CKRecord.ID`.
- **Change tracking:** each repo gains `updatedAt` + soft-delete tombstone
  (`deletedAt`) via a GRDB migration; a `SyncService` in Core observes
  writes (repo hooks) and enqueues pending changes.
- **Conflicts:** last-writer-wins on `updatedAt`, per record.
- **Privacy:** transcript text fields use `CKRecord.encryptedValues`
  (end-to-end encrypted). Toggle in Settings on both platforms, default off.
- **Mac distribution:** Developer ID apps can use CloudKit but need an
  iCloud entitlement + embedded provisioning profile → update
  `scripts/dist/build_app_bundle.sh` / `sign_notarize.sh`.
- **Spec:** requires an ADR-002 amendment (text-only opt-in sync) before
  implementation, plus `spec/01-data-model.md` updates.

## Implementation Steps

Each phase ends with a verifiable gate. Phases 1–2 can be built and tested on
a Mac with Xcode; Phase 3+ needs a physical iPhone for mic/background/keyboard.

### Phase 0 — Spec (before code)
1. Add requirements to `spec/kernel/requirements.yaml` (new area `IOS`):
   - REQ-IOS-001 iOS app dictation via keyboard launcher
   - REQ-IOS-002 background dictation session with heartbeat + timeout
   - REQ-IOS-003 keyboard inserts result via `textDocumentProxy`
   - REQ-IOS-004 onboarding: model download, mic, keyboard + Full Access
   - REQ-IOS-005 history / vocabulary / snippets screens
   - REQ-SYNC-001 opt-in CloudKit sync of words, snippets, settings, history text
2. Write ADR-013 (iOS companion app) and amend ADR-002 (opt-in text sync).
3. Update `spec/README.md` roadmap.

### Phase 1 — Core builds for iOS
1. Apply D4 guards; add `.iOS(.v18)` platform.
2. iOS `AudioRecorder` path with `AVAudioSession`.
3. **Gate:** `swift test` green on macOS; `xcodebuild -scheme MacParakeetCore
   -destination 'generic/platform=iOS Simulator' build` succeeds.

### Phase 2 — Host app skeleton
1. Create `iOS/` Xcode project, App Group, URL scheme, background audio mode.
2. Onboarding: model download (FluidAudio), mic permission, keyboard setup guide.
3. Home screen with in-app record button wired to `DictationService`
   (proves STT on device before keyboard work).
4. History, Vocabulary (processing mode, custom words, snippets), Settings —
   reuse ViewModels from `MacParakeetViewModels` where they compile.
5. **Gate:** simulator build runs; on device, in-app dictation returns text with
   pipeline applied; record ANE latency for a 10 s clip.

### Phase 3 — Keyboard + session
1. `Shared/SessionIPC.swift`: notify names, session file read/write, tests.
2. `DictationSessionController`: start/hold audio session, heartbeat,
   idle timeout, Live Activity, observe start/stop notifications, write results.
3. Keyboard extension: UI, liveness check, `AppLauncher`, insert + de-dup,
   recording/processing states, Full Access check.
4. **Gate (device):** in Notes/Messages/Safari: first tap opens app → Back →
   dictation inserts text; second dictation needs no app switch; app killed →
   next tap reopens app; phone call interruption recovers.

### Phase 4 — iCloud sync
1. Migration: `updatedAt`, `deletedAt` on synced tables (+ DB tests).
2. `SyncService` (Core) on `CKSyncEngine`; record mappers + mapper unit tests.
3. Settings toggle on Mac + iOS; Mac signing changes.
4. **Gate:** add word on Mac → appears on iPhone; delete on iPhone → gone on
   Mac; offline edits on both converge; toggle off stops all CloudKit traffic.

### Phase 5 — Ship
1. App Store metadata, privacy nutrition label (mic; no data collected unless
   sync/telemetry), keyboard Full Access justification for review.
2. TestFlight, then App Store.
3. Update CLAUDE.md, README, spec progress, traceability; archive this plan.

## Risks

| Risk | Mitigation |
|------|------------|
| Responder-chain `openURL` breaks in a future iOS | Isolated in `AppLauncher`; fallback instructions UI |
| CoreML/ANE inference throttled in background | Verify in Phase 2 on device with app backgrounded; fallback is transcribing when the app is foregrounded |
| App Review rejects background audio for "holding" mic | Live Activity indicator + user-visible session timeout; WisprFlow precedent |
| Model size on phone storage | Space check + clear messaging; consider smaller variant later |
| CloudKit with Developer ID Mac builds | Prototype entitlement/profile early in Phase 4 |
| Agent can't build iOS on Linux | Run Claude Code locally on a Mac with Xcode for Phases 1–3 |

## Files Changed

_(fill in when done)_
