# iOS App (MacParakeet for iPhone) Implementation Plan

> Status: **ACTIVE** - 2026-10-16 (Phases 1–3 code complete and simulator-verified; device gates and Phase 4 pending)

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
3. Background dictation session in the host app (WisprFlow-style: one tap opens the app, starts recording, and returns to the previous app; iOS ADR-001 Decision 8)
4. History, custom words, snippets, processing mode, settings screens

### Out of scope

- File transcription, YouTube, FFmpeg, video player, diarization, library view
- Optional LLM text features from Mac ADR-011 (summary/chat/refinement via user API
  keys). Their provider routing depends on `LocalCLIExecutor`, which uses
  `Process` and cannot build on iOS. Parakeet STT is unaffected.
- Non-Parakeet models
- A full typing keyboard (swipe, autocorrect, layouts)
- Shortcut/Action Button triggers (possible later via `AudioRecordingIntent`)
- iPad-specific layout, Sparkle, LemonSqueezy licensing
- Sync of any kind between Mac and iOS (per-device data for MVP; would need
  changes to both apps, revisit with its own ADR)

### Invariants (must not change)

- Mac app behavior unchanged; `swift test` stays green throughout
- No changes outside `iOS/`. The Mac app, its spec, and its docs do not know
  the iOS app exists; iOS only consumes existing Mac code. Upstream merges stay clean.
- Audio, text, and usage data never leave the device. The iOS app's only network
  access is the model download. No telemetry, crash reporting, feedback, or licensing
  code is compiled in (iOS ADR-001 Decision 6)
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
| `Services/LocalCLIExecutor`, `LocalCLILLMClient`, `RoutingLLMClient`, `LLMExecutionContext`, `LLMService`, `LLMClient` | `Process` | none (Mac ADR-011 LLM text features out of scope; Parakeet STT unaffected) |
| `Services/YouTubeDownloader`, `VideoStreamService`, `ThumbnailCacheService`, `BinaryBootstrap`, `ExportService`, `AutoSaveService`, `TranscriptionService`, `DiarizationService`, `SpeakerMerger` | file/YouTube features | none |
| `STT/FnKeyStateMachine`, `HotkeyTrigger`, `KeyCodeNames`, `DictationFlow/DictationFlowStateMachine` | hotkey flow | none; iOS session uses `dictation_session` state machine |

iOS replacements live in `iOS/CoreReplacements/` and compile into the same
`MacParakeetCoreiOS` target:

- `RecordingDeviceInfo.swift`: same public shape as the macOS struct
- `MobileAudioProcessor.swift`: `AudioProcessorProtocol` on `AVAudioEngine` +
  `AVAudioSession` (`.playAndRecord`, `.measurement`, `.allowBluetooth`), with
  interruption and route-change handling
- `MobileSTTClient.swift`: `STTClientProtocol` on FluidAudio 0.17.7, replacing
  the excluded `STT/STTClient.swift` (D6)

`DictationService`, `TextProcessingPipeline`, `TextRefinementService`,
repositories, models, and `DatabaseManager` compile unchanged.

Network-capable files are excluded even though they compile: `TelemetryService`,
`CrashReporter`, `FeedbackService`, `DiscoverService`, `DiscoverThoughtsService`,
`LemonSqueezyLicenseAPI`, and `EntitlementsService`. `CoreReplacements/Telemetry.swift`
is a no-op `Telemetry` facade, so shared calls to `Telemetry.send` compile and do
nothing.

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
`MacParakeetKeyboard` (extension), `MacParakeetWidgets` (Live Activity widget
extension; ActivityKit needs one to render), `MacParakeetiOSTests`.

The keyboard links **only** `Shared/`, never `MacParakeetCoreiOS` (keeps it far
under the memory cap). Only the host app opens the database, and it lives in the
app's **private** container (`AppPaths.databasePath`), not the App Group: the
keyboard never reads it, and keeping it out of the shared container removes the
`0xdead10cc` risk without needing GRDB suspension handling (which the shared
`DatabaseManager` does not expose).

Bundle IDs and the App Group come from `Config/Base.xcconfig`
(`BUNDLE_ID_PREFIX`, `APP_GROUP_ID`), overridable in a gitignored
`Config/Local.xcconfig` to sign for a device under another team. The App Group
reaches Swift through the `MacParakeetAppGroup` Info.plist key.

The test target is unhosted: it compiles `Shared/` and the testable `App/`
files directly and links `MacParakeetCoreiOS`, so tests never launch the app
(no DB).

### D6. Speech models (amended 2026-10-24, iOS ADR-001 Decision 7)

The English model (Parakeet TDT-CTC 110M) is bundled: `make models` runs
`scripts/fetch-bundled-model.sh`, which downloads it from Hugging Face into the
gitignored `Models/` folder, and `project.yml` copies that folder into the app.
`MobileSTTClient` loads it with `AsrModels.loadLocal`, so first launch needs no
network. Parakeet v3 (multilingual) is an optional download in Settings with a
free-space check, progress, and retry; its directory is excluded from iCloud
backup. iOS pins FluidAudio 0.17.7 (the Mac stays on 0.12.5) because 0.12.5 has
no 110M model.

## Implementation Steps

Each phase ends with a verifiable gate. Phases 1–2 can be built and tested on
a Mac with Xcode; Phase 3+ needs a physical iPhone for mic/background/keyboard.

### Phase 0 — Spec (before code) ✅
1. ✅ `iOS/spec/kernel/requirements.yaml`: `REQ-IOS-001`…`005`
   (status `active`, with acceptance criteria)
2. ✅ `iOS/spec/kernel/contracts/keyboard_session_ipc.yaml` (session/command
   files, notification names, keyboard view-state derivation, error codes)
3. ✅ `iOS/spec/kernel/state_machines/dictation_session.yaml`
4. ✅ `iOS/spec/adr/001-ios-companion-app.md` (accepted)
5. ✅ `iOS/spec/kernel/traceability.md`
6. ✅ **Gate:** iOS ADR-001 accepted by maintainer → flip requirements to `active`.

### Phase 1 — Core builds for iOS
1. `iOS/project.yml` with the `MacParakeetCoreiOS` target and D4 exclude list;
   `iOS/Makefile`; gitignore the generated `.xcodeproj`.
2. `CoreReplacements/`: `RecordingDeviceInfo`, `MobileAudioProcessor`, no-op `Telemetry`.
3. Extend the exclude list or add replacements until the target compiles.
4. **Gate:** `make -C iOS build` (iOS Simulator) succeeds; `swift test` green
   on macOS; `git diff --stat main -- . ':!iOS'` is empty.
   - ✅ Core, app, keyboard, and widget targets build for the iOS Simulator
     (2026-10-16; local Xcode 26.6, see note below); Mac diff gate empty.
   - ⚠️ `swift test` not re-run: on Xcode 26.6 FluidAudio 0.12.5 itself fails
     to compile (`sending 'asrManager' risks causing data races` in
     `StreamingAsrManager.swift`) for **macOS as well as iOS**, so this is a
     toolchain/upstream issue independent of iOS. Verification used a local
     FluidAudio copy in Swift 5 language mode; `project.yml` stays pinned to the
     Mac's 0.12.5. Resolve upstream (FluidAudio 0.12.6+ or older Xcode) before
     shipping.

### Phase 2 — Host app skeleton
1. ✅ Create `iOS/` Xcode project, App Group, URL scheme, background audio mode.
2. ✅ Onboarding: model download (FluidAudio), mic permission, keyboard setup guide.
3. ✅ Home screen with in-app record button wired to `DictationService`
   (proves STT on device before keyboard work).
4. ✅ History, Vocabulary (processing mode, custom words, snippets), Settings —
   reuse ViewModels from `MacParakeetViewModels` where they compile.
5. **Gate:** ✅ simulator build launches (onboarding renders, URL scheme
   registered); ⏳ on device, in-app dictation returns text with
   pipeline applied; record ANE latency for a 10 s clip.

### Phase 3 — Keyboard + session
1. ✅ `Shared/SessionIPC.swift`: notify names, session file read/write, tests.
2. ✅ `DictationSessionController`: start/hold audio session, heartbeat,
   idle timeout, Live Activity, observe start/stop notifications, write results.
3. ✅ Keyboard extension: UI, liveness check, `AppLauncher`, insert + de-dup,
   recording/processing states, Full Access check.
4. ⏳ **Gate (device):** in Notes/Messages/Safari: first tap opens app → Back →
   dictation inserts text; second dictation needs no app switch; app killed →
   next tap reopens app; phone call interruption recovers.

### Phase 4 — Ship
1. App Store metadata, privacy nutrition label (mic; Data Not Collected), keyboard Full Access justification for review.
2. TestFlight, then App Store.
3. Update `iOS/CLAUDE.md`, `iOS/spec/kernel/traceability.md`, requirement
   statuses; archive this plan to `iOS/plans/completed/`.

## Risks

| Risk | Mitigation |
|------|------------|
| Responder-chain `openURL` breaks in a future iOS | Isolated in `AppLauncher`; fallback instructions UI |
| CoreML/ANE inference throttled in background | Verify in Phase 2 on device with app backgrounded; fallback is transcribing when the app is foregrounded |
| App Review rejects background audio for "holding" mic | Live Activity indicator + user-visible session timeout; WisprFlow precedent |
| Private host detection (`_hostBundleID`, `_UIRemoteKeyboards`) changes or is rejected | One file each, runtime-checked; swipe-back hint fallback; Settings toggle |
| Model size on phone storage | English bundled (~400 MB); multilingual optional with space check |
| `MobileSTTClient` written against FluidAudio 0.17.7 without a compiler (Linux agent) | First Mac build must confirm it compiles; tests cover the settings logic, not FluidAudio calls |
| Agent can't build iOS on Linux | Run Claude Code locally on a Mac with Xcode for Phases 1–3 |
| GRDB DB in App Group container killed on suspend (`0xdead10cc`) | DB lives in the app's private container; only IPC JSON (atomic writes, no locks) is shared |

## Files Changed

Phases 1–3 (2026-10-16):

- `project.yml`, `Makefile`, `Config/Base.xcconfig`, `.gitignore`
- `CoreReplacements/`: `RecordingDeviceInfo.swift`, `MobileAudioProcessor.swift`
- `Shared/`: `AppGroup.swift`, `SessionIPC.swift`, `KeyboardViewState.swift`, `SessionActivityAttributes.swift`
- `App/`: `MacParakeetiOSApp.swift`, `AppEnvironment.swift`, `AppSettings.swift`,
  `DictationSessionStateMachine.swift`, `DictationSessionController.swift`,
  `SessionActivityPresenter.swift`, `OnboardingViewModel.swift`, `HistoryViewModel.swift`,
  `Views/` (Root, Home, Onboarding, History, Vocabulary, CustomWords, TextSnippets, Settings)
- `Keyboard/`: `KeyboardViewController.swift`, `KeyboardModel.swift`, `KeyboardView.swift`, `AppLauncher.swift`
- `Widgets/SessionLiveActivity.swift`
- `Tests/`: 55 tests (`DictationSessionControllerTests`, `SessionIPCTests`,
  `KeyboardViewStateTests`, `OnboardingViewModelTests`, `HistoryViewModelTests`,
  `TextPipelineParityTests`), all passing on the iOS 17 simulator
- Kernel: `app_session_requested` event added to `dictation_session.yaml` for in-app dictation

Speech models + audit fixes (2026-10-24):

- `CoreReplacements/MobileSTTClient.swift` (new), `project.yml` (FluidAudio 0.17.7, exclude `STT/STTClient.swift`, bundled model resource), `Makefile` (`models`, `distclean`), `scripts/fetch-bundled-model.sh` (new), `.gitignore`
- `App/SpeechModelSettingsViewModel.swift` (new), `App/Views/SettingsView.swift`, `App/OnboardingViewModel.swift`, `App/Views/OnboardingView.swift`, `App/AppEnvironment.swift`, `App/AppSettings.swift`, `App/MacParakeetiOSApp.swift`, `App/Views/RootView.swift`
- `Keyboard/KeyboardViewController.swift`: rebuild the SwiftUI view only when `needsInputModeSwitchKey` changes (was every layout pass)
- `Tests/SpeechModelSettingsViewModelTests.swift` (new), `Tests/OnboardingViewModelTests.swift`

Auto-return (2026-10-24):

- `Shared/SessionIPC.swift` (`SessionLaunch`), `Shared/PendingLaunchStore.swift` (new)
- `Keyboard/KeyboardModel.swift`, `Keyboard/KeyboardViewController.swift`, `Keyboard/HostAppDetector.swift` (new)
- `App/DictationSessionController.swift` (`handle(url:)` applies the launch's start command), `App/HostReturnController.swift` (new), `App/RemoteKeyboardHostObserver.swift` (new), `App/AppEnvironment.swift`, `App/AppSettings.swift`, `App/MacParakeetiOSApp.swift`, `App/Views/HomeView.swift`, `App/Views/RootView.swift`, `App/Views/SettingsView.swift`
- `Tests/HostReturnControllerTests.swift` (new), `Tests/DictationSessionControllerTests.swift`, `Tests/SessionIPCTests.swift`
- Kernel: REQ-IOS-007, REQ-IOS-003 amended, contract `launch_query`, state machine invariant, ADR Decision 8
