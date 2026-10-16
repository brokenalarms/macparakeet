# iOS App (MacParakeet for iPhone) Implementation Plan

> Status: **PROPOSAL** - 2026-10-16 (Phase 0 spec complete; awaiting ADR-013 acceptance)

## Overview

Ship an iPhone companion to MacParakeet scoped to the **WisprFlow feature set**:
dictate into any app via a minimal custom keyboard, with Parakeet running locally
on the Neural Engine, the same clean pipeline (custom words, snippets, filler
removal), and dictation history. The iOS app is standalone: all data is
per-device, with no sync to the Mac app.

The keyboard is a **launcher, not a real keyboard**: a mic button, globe key, and
a few utility keys. Users switch back to their normal keyboard (globe) to type.

### In scope

1. iOS app in `iOS/` compiling `Sources/MacParakeetCore` in place (Parakeet STT,
   pipeline, GRDB repos) with zero edits to the Mac sources
2. Minimal keyboard extension that triggers dictation and inserts the result
3. Background dictation session in the host app (WisprFlow-style "open app → tap Back")
4. History, custom words, snippets, processing mode, settings screens

### Out of scope

- File transcription, YouTube, FFmpeg, video player, diarization, library view
- All LLM features (the routing client depends on `LocalCLIExecutor`, which
  uses `Process` and cannot build on iOS)
- Non-Parakeet models
- A full typing keyboard (swipe, autocorrect, layouts)
- Shortcut/Action Button triggers (possible later via `AudioRecordingIntent`)
- iPad-specific layout, Sparkle, LemonSqueezy licensing
- Sync of any kind between Mac and iOS (per-device data for MVP; would need
  changes to both apps, revisit with its own ADR)

### Invariants (must not change)

- Mac app behavior unchanged; `swift test` stays green throughout
- No changes outside `iOS/`, `spec/`, and `plans/`: `Sources/`, `Tests/`,
  `Package.swift`, and `scripts/` are untouched. Mac upstream merges stay clean.
- Audio and text never leave the device; the iOS app's only network calls are
  model download and telemetry (opt-out, as on Mac)
- `iOS/` stays self-contained, so it can move to its own repo by replacing the
  `../Sources` path with a submodule

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

### D4. Sharing Core without editing it

The iOS project compiles files from `../Sources/MacParakeetCore` directly into
an iOS framework target (`MacParakeetCoreiOS`), **excluding** macOS-only files.
The iOS app provides replacements for the excluded files that shared code needs.
No `#if os(macOS)` guards and no `Package.swift` changes. The module name stays
`MacParakeetCore` (`PRODUCT_MODULE_NAME`) so the shared files' imports work unchanged.

Excluded from the iOS build (verified by grepping cross-references):

| Excluded | Why | Shared code that needs a replacement |
|----------|-----|--------------------------------------|
| `Audio/AudioRecorder.swift`, `AudioDeviceManager.swift` | CoreAudio device APIs | `RecordingDeviceInfo` (used by `AudioProcessorProtocol`, `AudioProcessor`, `TelemetryEvent`) |
| `Audio/AudioProcessor.swift`, `AudioFileConverter.swift` | FFmpeg file conversion | `AudioProcessorProtocol` conformer for `DictationService` |
| `Services/AccessibilityService`, `ClipboardService`, `PermissionService`, `LaunchAtLoginService` | AppKit / AX / SMAppService | none; iOS has its own mic permission helper |
| `Services/LocalCLIExecutor`, `LocalCLILLMClient`, `RoutingLLMClient`, `LLMExecutionContext`, `LLMService` | `Process` | none (LLM out of scope) |
| `Services/YouTubeDownloader`, `VideoStreamService`, `ThumbnailCacheService`, `BinaryBootstrap`, `ExportService`, `AutoSaveService`, `TranscriptionService`, `DiarizationService` | file/YouTube features | none |
| `STT/FnKeyStateMachine`, `HotkeyTrigger`, `KeyCodeNames`, `DictationFlow/DictationFlowStateMachine` | hotkey flow | none; iOS session uses `ios_dictation_session` |

iOS replacements live in `iOS/CoreReplacements/` and compile into the same
`MacParakeetCoreiOS` target:

- `RecordingDeviceInfo.swift`: same public shape as the macOS struct
- `MobileAudioProcessor.swift`: `AudioProcessorProtocol` on `AVAudioEngine` +
  `AVAudioSession` (`.playAndRecord`, `.measurement`, `.allowBluetooth`), with
  interruption and route-change handling

`DictationService`, `STTClient`, `TextProcessingPipeline`, `TextRefinementService`,
repositories, models, `DatabaseManager`, and telemetry compile unchanged.
`CrashReporter` (MachO) and `SystemInfo` (`sysctlbyname`) are expected to
compile on iOS; Phase 1 verifies this and excludes them if not.

From `Sources/MacParakeetViewModels`, only `CustomWordsViewModel` and
`TextSnippetsViewModel` are compiled in. Other iOS screens get iOS-specific
ViewModels in `iOS/App/`.

If a future upstream change makes a shared file reference an excluded type, the
iOS build breaks at that point; fix it by adding a replacement in
`iOS/CoreReplacements/`, never by editing `Sources/`.

### D5. Project structure

The Xcode project is generated with **XcodeGen** from `iOS/project.yml`. The
`.xcodeproj` is gitignored, so the project definition is a reviewable,
agent-editable YAML file rather than a `.pbxproj`. GRDB and FluidAudio are
declared as SPM packages in `project.yml`, pinned to the same versions as
`Package.swift`.

```
iOS/
├── project.yml                     # XcodeGen: targets, sources, excludes, packages
├── Makefile                        # `make project`, `make build`, `make test`
├── CoreReplacements/               # iOS versions of excluded Core types (D4)
├── App/                            # SwiftUI host app
│   ├── MacParakeetiOSApp.swift
│   ├── DictationSessionController.swift   # session state machine, IPC, heartbeat
│   ├── Views/ (Onboarding, Home, History, Vocabulary, Settings)
│   └── Info.plist  (UIBackgroundModes: audio; URL scheme macparakeet://)
├── Keyboard/                       # keyboard extension
│   ├── KeyboardViewController.swift
│   ├── KeyboardView.swift          # SwiftUI: mic, globe, space, delete, return
│   └── AppLauncher.swift
├── Shared/                         # compiled into App and Keyboard
│   ├── SessionIPC.swift            # Darwin notify names + App Group files
│   └── AppGroup.swift
└── Tests/                          # XCTest target for App + Shared
```

Targets: `MacParakeetCoreiOS` (framework), `MacParakeetiOS` (app),
`MacParakeetKeyboard` (extension), `MacParakeetiOSTests`.

The keyboard links **only** `Shared/`, never `MacParakeetCoreiOS` (keeps it far
under the memory cap). Only the host app opens the database, which lives in the
App Group container.

### D6. Model download

FluidAudio downloads Parakeet v3 into the app container on first launch
(onboarding step, Wi-Fi recommended, progress UI, resumable). Check free space
before download. Exclude model dir from iCloud backup (`isExcludedFromBackup`).

## Implementation Steps

Each phase ends with a verifiable gate. Phases 1–2 can be built and tested on
a Mac with Xcode; Phase 3+ needs a physical iPhone for mic/background/keyboard.

### Phase 0 — Spec (before code) ✅
1. ✅ `spec/kernel/requirements.yaml`: `REQ-IOS-001`…`005`
   (status `proposed`, with acceptance criteria)
2. ✅ `spec/kernel/contracts/ios_keyboard_session_ipc.yaml` (session/command
   files, notification names, keyboard view-state derivation, error codes)
3. ✅ `spec/kernel/state_machines/ios_dictation_session.yaml`
4. ✅ ADR-013 (proposed)
5. ✅ `spec/README.md` roadmap, `spec/01-data-model.md`, `traceability.md`
6. **Gate:** ADR-013 accepted by maintainer → flip requirements to `active`.

### Phase 1 — Core builds for iOS
1. `iOS/project.yml` with the `MacParakeetCoreiOS` target and D4 exclude list;
   `iOS/Makefile`; gitignore the generated `.xcodeproj`.
2. `CoreReplacements/`: `RecordingDeviceInfo`, `MobileAudioProcessor`.
3. Extend the exclude list or add replacements until the target compiles.
4. **Gate:** `make -C iOS build` (iOS Simulator) succeeds; `swift test` green
   on macOS; `git diff main -- Sources Tests Package.swift scripts` is empty.

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

### Phase 4 — Ship
1. App Store metadata, privacy nutrition label (mic; no data collected except
   opt-out telemetry), keyboard Full Access justification for review.
2. TestFlight, then App Store.
3. Update CLAUDE.md, README, spec progress, traceability; archive this plan.

## Risks

| Risk | Mitigation |
|------|------------|
| Responder-chain `openURL` breaks in a future iOS | Isolated in `AppLauncher`; fallback instructions UI |
| CoreML/ANE inference throttled in background | Verify in Phase 2 on device with app backgrounded; fallback is transcribing when the app is foregrounded |
| App Review rejects background audio for "holding" mic | Live Activity indicator + user-visible session timeout; WisprFlow precedent |
| Model size on phone storage | Space check + clear messaging; consider smaller variant later |
| Agent can't build iOS on Linux | Run Claude Code locally on a Mac with Xcode for Phases 1–3 |
| GRDB DB in App Group container killed on suspend (`0xdead10cc`) | Enable GRDB `observesSuspensionNotifications`; only the host app opens the DB |

## Files Changed

_(fill in when done)_
