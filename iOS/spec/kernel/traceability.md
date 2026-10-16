# iOS Traceability Matrix

> Status: **ACTIVE** — planned paths; update when implemented.

| Requirement | Contract / State Machine | Source Files | Test Files |
|------------|-------------------------|-------------|------------|
| REQ-IOS-001 | — | `iOS/project.yml`, `iOS/CoreReplacements/MobileAudioProcessor.swift`, `iOS/App/` | `swift test` (macOS), `make -C iOS build` |
| REQ-IOS-002 | `contracts/keyboard_session_ipc.yaml`, `state_machines/dictation_session.yaml` | `iOS/App/DictationSessionController.swift`, `iOS/Shared/SessionIPC.swift` | `iOS/Tests/DictationSessionControllerTests.swift`, `iOS/Tests/SessionIPCTests.swift` |
| REQ-IOS-003 | `contracts/keyboard_session_ipc.yaml` | `iOS/Keyboard/KeyboardViewController.swift`, `iOS/Keyboard/AppLauncher.swift`, `iOS/Shared/SessionIPC.swift` | `iOS/Tests/KeyboardViewStateTests.swift` |
| REQ-IOS-004 | — | `iOS/App/Views/Onboarding/`, `iOS/App/OnboardingViewModel.swift` | `iOS/Tests/OnboardingViewModelTests.swift` |
| REQ-IOS-005 | — | `iOS/App/Views/`, `Sources/MacParakeetViewModels/CustomWordsViewModel.swift`, `TextSnippetsViewModel.swift` (compiled in, unedited) | existing Mac ViewModel tests, `iOS/Tests/` |
