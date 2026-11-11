# Development log

## Day1 — 2026-11-07

### Completed

- Inspected the existing application-use installation and compared Vercel agent-desktop with Open Computer Use.
- Selected Open Computer Use revision `1263960a888e77297e551b560206bd44fd1b53e5` as the source for targeted background window capture and input.
- Confirmed the requirement: every application-use operation is background-only; there is no foreground option or fallback.
- Built the dedicated runtime on macOS 15.7 arm64 with a macOS 14 deployment target; runtime permission checks pass without prompting.
- Implemented the persistent private CLI session, AX/OCR/icon hints and isolated-window image recognition. Offline OCR and the existing local CoreML model passed their smoke check.
- Completed the initial policy and adapter unit tests. The full Swift suite exposed one outdated virtual-display error expectation; the corrected policy tests now cover rejection even when display placement is configured on.
- Confirmed visually that the live AppKit fixture screenshot contains the fully occluded target window; investigated the initial image-marker failure before proceeding with acceptance.
- Corrected the acceptance image decoder to honor the embedded display ICC profile; the original marker tolerance now passes. Delayed fixture window creation until after AppKit launch completed to avoid a test-only automatic activation.
- Hardened exact AX/window identity, live editable-focus ownership and expected control matching, forbidden lifecycle/system keys, and window-control clicks including coordinate hints.
- Verified AppKit text areas can omit Enabled/Editable while exposing writable Value/SelectedText. Those absent attributes are accepted only with positive text-editability evidence; explicit false and AX read errors still fail.
- The final full Swift suite passes: 474 tests, 8 skipped, zero failures. Adapter tests: 35 passed. Monitor classification tests: 3 passed. Skill format validation passed.
- Live staged-runtime acceptance passed occluded capture, a real button click, Chinese/emoji/combining-character text insertion and a delivered arrow key. During the 1,832-sample interval, no foreground application/window or physical pointer change was observed.
- Corrected pixel and line scroll events to include exact window identity and window-local coordinates; each event is posted once, without mouse movement or activation. AX page-action errors are checked.
- Final live acceptance passed all nine GUI checks, including a 200-pixel document scroll, rejected right-click, rejected fill on a button, and 12 forbidden shortcut combinations. Continuous notification-assisted monitoring recorded 1,868 samples, zero foreground/window/pointer changes, and a maximum sampling gap of 18.60 ms. The test fixture stayed fully occluded.
- Installed the verified bytes as the active skill runtime and redirected the global application-use command to the same wrapper. The old skill and command link are outside the active skill directory as recovery material; no old-executable fallback exists.
- Verified both installed entrypoints, runtime permissions, app discovery, matching runtime SHA-256, and Codex force-reloaded skill discovery (enabled, one matching entry, no errors). Stopped the verification session.

### Remaining compatibility limits

- No unfinished installation or acceptance steps remain. Real GUI coverage is the independent AppKit fixture on macOS 15.7; arbitrary third-party applications have not all been certified.
- A third-party application can initiate activation itself in response to its own callback. No route may compensate by restoring user focus or fall back to foreground input.

### Decisions and open issues

- Failure to perform an action in the background must return an error.
- Never restore the user's foreground window or pointer to disguise a violation.
- Keep original runtime files as inactive recovery material; the new entrypoint must never invoke them.
- Native GUI permissions and the supported workflow were validated on this macOS 15.7 machine.
- Some apps may activate themselves in response to a semantic action; unsupported behavior must be reported and excluded from a claim of compatibility.

### Visual cursor follow-up — completed

- User approved enabling and demonstrating the independent cursor display.
- Confirmed the installed adapter and runtime explicitly disabled it; the inherited overlay already uses a nonactivating panel that ignores mouse events and cannot become key/main.
- Enable the display only after AppKit finishes a prohibited, windowless launch. Reset it on session shutdown.
- Remove the inherited target-missing order-front behavior and add movement feedback to verified text input and scrolling.
- Show a dedicated visible demo window without activating it. Record only the owned demo and cursor windows for a real animated preview, while monitoring foreground/window/pointer stability.
- Release build succeeds. Twenty-six relevant native policy/ordering tests and 36 adapter tests pass. The private session now waits for the native process and cursor cleanup before acknowledging session-stop.
- The visible demo completed five real input actions and verified that the cursor disappears after the target exits while the runtime remains alive. The isolated recorder captured a 20-second GIF with 188 frames, including 178 actual overlay frames. No desktop pixels were recorded.
- The first complete demonstration contained desktop activity, so its stability result remained inconclusive. The subsequent user-coordinated quiet comparison passed all five real input actions and target-loss cleanup: 2,322 notification-assisted samples, no observed foreground/window/pointer changes, maximum sampling gap 23.11 ms; 180 recorded frames included 169 real cursor frames.
- The cursor-enabled runtime also passed the fully occluded acceptance sequence, including real scroll and refused inputs: 2,471 samples, no observed foreground/window/pointer changes, maximum gap 17.91 ms. The fixture remained covered by the sentinel window.
- Installed the verified runtime, adapter and instructions. Copied the reference cursor image beside the executable; a bare executable bundle lookup verified that this layout resolves the image without the source checkout. Runtime, adapter and image hashes match the tested sources.
- Both installed entrypoints report `backgroundOnly: true`, `visualCursorEnabled: true` and existing permissions granted, using the same native process. Session shutdown completed and that process exited. The previous installed background version remains in a separate recovery backup.
- Coverage remains the owned AppKit fixture on macOS 15.7. Notification-assisted sampling does not certify arbitrary third-party application callbacks or arbitrarily brief changes between samples.

## Day2 — 2026-11-11

### todo_list

- [x] Inspect the installed adapter, native input checks, repository guidance and prior Terminal verification.
- [x] Preserve the current installed files and touched source files before editing.
- [x] Recognize Terminal's keyboard-driven shell without relaxing other text-control or focus checks.
- [x] Run regression tests and build the dedicated runtime.
- [x] Verify actual background input through application-use in the existing idle Terminal window.
- [x] Install the verified runtime and instructions, check installed behavior and record results.

### Completed

- The user requested integration of the previously verified upstream `sky_key` behavior.
- Confirmed `fill` already routes to `sky_key`; the writable AX text-attribute requirement was the blocking check.
- Added a narrow exception for the real Terminal bundle's `AXTextArea` described as `shell`. Explicit false flags, process/window ownership and expected-element matching still reject input; the same validation runs before each text chunk.
- Added regression coverage for the Terminal case and its rejected app/control/focus variants; updated skill instructions and architecture.

### Validation and installation

- Release build passed. Native background/cursor policy tests: 25 passed; adapter tests: 36 passed. Source and installed skill format validation passed. The build retains an existing unrelated cursor-renderer warning.
- The first two monitoring intervals contained desktop activity and remain inconclusive; neither sent text. After user coordination, the existing Terminal shell received the full marker command through `fill`, then executed it through `sendkey Return`, returning `APPLICATION_USE_STAGE_OK`.
- The confirmed interval contained 6,134 samples over about 61.43 seconds, with zero foreground-app, foreground-window or physical-pointer changes, zero window-read failures and a maximum sampling gap of 18.20ms. The monitor remained alive through private-session shutdown. Final screenshot and command output were inspected.
- Installed the same verified release bytes after stopping the previous private session. Runtime SHA-256: `1438e43f5a7fcdbf21f5d6d384b7be11ea0a92660d1adb50b50e060a1c04844a`. Installed instructions match the source skill; the global command still resolves to the installed wrapper.
- Installed `doctor` reports existing permissions granted, `backgroundOnly: true`, and `visualCursorEnabled: true`; the installed snapshot confirms the same Terminal shell and successful marker output. Previous runtime and instructions remain in a separate recovery backup.
- No pending integration work remains. This covers existing Terminal shell input on the tested macOS version, not new-window creation or all terminal applications; notifications and sampling cannot certify arbitrarily brief disturbances.

### GitHub source packaging — 2026-11-11

- [x] Confirm the existing `scut204/application-use` repository and inspect its Go/Swift baseline.
- [x] Add the tested background runtime source, independent Swift package, portable Python launcher, policy tests and fixture checks.
- [x] Preserve the previous CLI source and npm packaging; document their separate build path.
- [x] Include upstream licenses and provenance; remove workstation-specific skill/model paths from the published entrypoint.
- [x] Use procedural cursor drawing without redistributing extracted reference artwork or the optional icon model.
- [x] Verify source-package build and relevant tests: release build, 25 native policy tests, 36 Python adapter tests and 4 monitor tests passed.
- [ ] Synchronize remote and publish the reviewed source update.

The earlier Day1/Day2 entries describe the original local implementation and
its historical checks. Packaging checks below refer to this repository version.

Packaging verification completed on macOS arm64 with Swift 6.2.4. The staged
launcher help and shell syntax checks pass. The build retains an upstream
`nonisolated(unsafe)` compiler warning in the glyph renderer; it is not a build
failure. No live GUI input or active local installation was changed by this
packaging task. GitHub publication still requires an authenticated write path;
HTTPS has no available credential and SSH authentication was rejected.
