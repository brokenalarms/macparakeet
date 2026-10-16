# ADR-013: iOS Companion App (Keyboard-Launched Dictation + Opt-in iCloud Sync)

> Status: **PROPOSED** | Date: 2026-10-16
> Plan: `plans/active/ios-app.md`
> Kernel: `REQ-IOS-001`…`REQ-IOS-005`, `REQ-SYNC-001`

## Context

MacParakeet's dictation (WisprFlow-style) is Mac-only. Users want the same local Parakeet dictation on iPhone, with their custom words and snippets available on both devices.

iOS imposes constraints the Mac app never faced:

1. **No global hotkey or paste simulation.** The only system-wide text-insertion surface is a custom keyboard extension (`UIInputViewController.textDocumentProxy`).
2. **Keyboard extensions have a ~50–70 MB memory cap** and cannot run Parakeet (model weights + ~66 MB working memory). They also cannot activate the microphone themselves in a way that survives app switching.
3. **No public API to open the containing app from a keyboard.**
4. **No `Process`, FFmpeg, yt-dlp, AppKit, Accessibility APIs.**

## Decision

### 1. Scope: dictation only

iOS v1 ships the dictation half of the product: in-app dictation, a launcher keyboard, history, vocabulary (processing mode, custom words, snippets), settings, and opt-in sync. File transcription, YouTube, export, playback, diarization, local CLI LLM providers, Sparkle, and licensing are out of scope. This preserves "simplicity is the product": iOS gets one mode, done well.

### 2. All audio and STT run in the host app

The keyboard is a launcher (mic, globe, space, delete, return), not a typing keyboard. The host app holds an `AVAudioSession` under the `audio` background mode and runs `DictationService` unchanged. Keyboard ↔ app communication uses Darwin notifications for signals and single-writer JSON files in the App Group for payloads (contract: `spec/kernel/contracts/ios_keyboard_session_ipc.yaml`; flow: `spec/kernel/state_machines/ios_dictation_session.yaml`).

The first mic tap with no live session opens the app via `macparakeet://session/start` using the responder-chain `openURL` technique, isolated in one file behind a protocol. The user returns with the system "◀ Back" link; subsequent dictations need no app switch until the session idles out (default 5 min). A Live Activity is shown for the whole time the mic session is held.

The keyboard requires Full Access (App Group access). It never links `MacParakeetCore` and never opens the database.

### 3. One Core target, platform-guarded

`MacParakeetCore` and `MacParakeetViewModels` gain an iOS platform; macOS-only files are wrapped in `#if os(macOS)` rather than split into a new target. Core stays UI-free (no UIKit or SwiftUI). The iOS app and keyboard live in an Xcode project under `iOS/` that references the local package, because SPM cannot build app extensions. Mac build scripts are unchanged.

### 4. Minimum iOS 17

`Package.swift` stays at `swift-tools-version: 5.9`, whose newest iOS platform constant is `.v17`. Raising the tools version to reach `.v18` would also move every target into the Swift 6 language mode, which is an unrelated migration. iOS 17 covers every API this ADR needs (`CKSyncEngine`, Live Activities, `AVAudioApplication` record permission).

### 5. Opt-in iCloud sync (amends ADR-002)

Sync uses `CKSyncEngine` against the user's **private** CloudKit database. It carries **text only**: custom words, snippets, an allowlist of settings, and non-hidden dictation text. Transcript and snippet text use `CKRecord.encryptedValues` (end-to-end encrypted with the user's iCloud keys). Sync is **off by default**, per device; while off, no CloudKit API is called. The full rules are in `spec/kernel/contracts/icloud_sync.yaml`.

Schema impact: synced tables already have `updatedAt`; they gain a nullable `deletedAt` tombstone column. Because `custom_words.word` and `text_snippets.trigger` are unique, independently created duplicates are merged by natural key rather than by UUID.

The Mac app needs an iCloud entitlement and an embedded provisioning profile for CloudKit under Developer ID distribution.

## Rationale

- **Host-app STT is the only viable option.** The keyboard memory cap rules out on-keyboard inference; Apple's `SFSpeechRecognizer` would break ADR-001 and ADR-002.
- **The launcher-keyboard pattern is proven** by WisprFlow and similar apps that have passed App Review with background audio plus a visible indicator.
- **Single-writer files** avoid cross-process write races without file locks. A held lock on a shared-container file while suspended gets the app killed (`0xdead10cc`).
- **Private-database CloudKit with encrypted fields** keeps us at zero server infrastructure and zero access to user text, which is closer to ADR-002's spirit than any self-hosted sync.

## Consequences

### Positive

- Same model, pipeline, and vocabulary on Mac and iPhone; Core gains no UI dependency.
- No new server infrastructure; no MacParakeet-operated storage of user content.
- With sync off, the iOS app is as private as the Mac app.

### Negative

- First dictation after the session idles out requires an app round-trip.
- Full Access triggers Apple's "can transmit anything you type" warning; onboarding must explain it.
- The responder-chain app launch is unsupported API and may break in a future iOS release.
- `#if os(macOS)` guards spread across ~20 Core files.
- Mac signing gains a provisioning profile, which `scripts/dist/` must handle.

### Risks

See `plans/active/ios-app.md` § Risks.

## References

- ADR-001, ADR-007: Parakeet via FluidAudio CoreML (shared on iOS)
- ADR-002: Local-first processing (amended by this ADR for opt-in text sync)
- ADR-004: Deterministic pipeline (unchanged, shared)
- ADR-012: Telemetry (applies to iOS unchanged, opt-out)
