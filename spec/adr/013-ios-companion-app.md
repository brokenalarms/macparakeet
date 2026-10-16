# ADR-013: iOS Companion App (Keyboard-Launched Dictation)

> Status: **PROPOSED** | Date: 2026-10-16
> Plan: `plans/active/ios-app.md`
> Kernel: `REQ-IOS-001`…`REQ-IOS-005`

## Context

MacParakeet's dictation (WisprFlow-style) is Mac-only. Users want the same local Parakeet dictation on iPhone.

iOS imposes constraints the Mac app never faced:

1. **No global hotkey or paste simulation.** The only system-wide text-insertion surface is a custom keyboard extension (`UIInputViewController.textDocumentProxy`).
2. **Keyboard extensions have a ~50–70 MB memory cap** and cannot run Parakeet (model weights + ~66 MB working memory). They also cannot activate the microphone themselves in a way that survives app switching.
3. **No public API to open the containing app from a keyboard.**
4. **No `Process`, FFmpeg, yt-dlp, AppKit, Accessibility APIs.**

## Decision

### 1. Scope: dictation only

iOS v1 ships the dictation half of the product: in-app dictation, a launcher keyboard, history, vocabulary (processing mode, custom words, snippets), and settings. All data is per-device; nothing syncs with the Mac app. File transcription, YouTube, export, playback, diarization, local CLI LLM providers, Sparkle, and licensing are out of scope. This preserves "simplicity is the product": iOS gets one mode, done well.

### 2. All audio and STT run in the host app

The keyboard is a launcher (mic, globe, space, delete, return), not a typing keyboard. The host app holds an `AVAudioSession` under the `audio` background mode and runs `DictationService` unchanged. Keyboard ↔ app communication uses Darwin notifications for signals and single-writer JSON files in the App Group for payloads (contract: `spec/kernel/contracts/ios_keyboard_session_ipc.yaml`; flow: `spec/kernel/state_machines/ios_dictation_session.yaml`).

The first mic tap with no live session opens the app via `macparakeet://session/start` using the responder-chain `openURL` technique, isolated in one file behind a protocol. The user returns with the system "◀ Back" link; subsequent dictations need no app switch until the session idles out (default 5 min). A Live Activity is shown for the whole time the mic session is held.

The keyboard requires Full Access (App Group access). It never links `MacParakeetCore` and never opens the database.

### 3. iOS lives in `iOS/`; Mac sources are not edited

The iOS app is a self-contained `iOS/` directory with an XcodeGen-generated Xcode project (SPM cannot build app extensions). Its framework target compiles `../Sources/MacParakeetCore` in place, excluding macOS-only files, and supplies iOS replacements for the few excluded types that shared code references (`RecordingDeviceInfo`, an `AudioProcessorProtocol` conformer). `Sources/`, `Tests/`, `Package.swift`, and `scripts/` stay untouched, so the Mac app is unchanged and upstream merges stay clean. Moving `iOS/` to its own repo later only means swapping the `../Sources` path for a submodule. The exclude list is in `plans/active/ios-app.md` D4.

### 4. Minimum iOS 17

iOS 17 is the lowest version providing every API the app needs (`AVAudioApplication` record permission, Live Activities).

### 5. No sync

The iOS app keeps its own database, vocabulary, and settings. Sync would require changes to the Mac app as well; it is deferred to a future ADR. ADR-002 applies unchanged: audio and text never leave the device.

## Rationale

- **Host-app STT is the only viable option.** The keyboard memory cap rules out on-keyboard inference; Apple's `SFSpeechRecognizer` would break ADR-001 and ADR-002.
- **The launcher-keyboard pattern is proven** by WisprFlow and similar apps that have passed App Review with background audio plus a visible indicator.
- **Single-writer files** avoid cross-process write races without file locks. A held lock on a shared-container file while suspended gets the app killed (`0xdead10cc`).

## Consequences

### Positive

- Same model and pipeline on Mac and iPhone, compiled from the same source files.
- No new server infrastructure; the iOS app is as private as the Mac app.
- No Mac app behavior change.

### Negative

- First dictation after the session idles out requires an app round-trip.
- Full Access triggers Apple's "can transmit anything you type" warning; onboarding must explain it.
- The responder-chain app launch is unsupported API and may break in a future iOS release.
- The iOS build can break when upstream changes a shared file to depend on an excluded one; the fix is a replacement in `iOS/`, never an edit to `Sources/`.
- No LLM features on iOS: the shared LLM routing depends on `Process`.
- Custom words and snippets must be entered separately on each device.

### Risks

See `plans/active/ios-app.md` § Risks.

## References

- ADR-001, ADR-007: Parakeet via FluidAudio CoreML (shared on iOS)
- ADR-002: Local-first processing (applies unchanged)
- ADR-004: Deterministic pipeline (unchanged, shared)
- ADR-012: Telemetry (applies to iOS unchanged, opt-out)
