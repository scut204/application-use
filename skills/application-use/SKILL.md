---
name: application-use
description: Operate named macOS apps in the background through Accessibility, isolated window screenshots, OCR and local icon recognition. Use for desktop UI inspection, clicking, text entry and scrolling while the user works in another app.
allowed-tools: Bash(application-use:*), Bash(./build/background/scripts/application-use:*)
---

# Application Use

Build this fork with `make background` first (see the repository README), then add `build/background/scripts` to PATH. Existing npm packages contain the older implementation.

Use this background entrypoint for every operation:

```bash
application-use --help
```

All operations are background-only. There is no foreground mode. An unsupported operation returns an error; never substitute the old npm executable, global mouse/keyboard events, a clipboard paste, or a focus-and-restore sequence.

A separate visual cursor shows movement and click feedback over the target window. It does not receive mouse clicks or become the active window. Windows covering the target also cover this cursor; never raise the target to make the cursor visible. The cursor disappears when its target closes, the session stops, or the visual idle timer expires.

## Observe, act, verify

1. Use `search "name"` to identify the app, then `snapshot --appName "Name"` to bind a running app and inspect its window.
2. Use the returned letter hints. `AX` identifies app controls, `OCR` identifies visible text, and `ICON` identifies locally detected icon regions. Icon class names do not establish what a button does; inspect the screenshot when its meaning is unclear.
3. After an action, inspect the returned updated state. A completed input event does not by itself prove the desired result occurred.

Hints belong to the latest snapshot of one process and window. They expire after two minutes. The runtime revalidates them before input; if stale or ambiguous, take a new snapshot and reassess. Do not automatically repeat an input after a timeout or a failed after-action observation, because the action may already have happened.

```bash
application-use snapshot --appName "TextEdit"
application-use click A --appName "TextEdit"
application-use fill B "hello" --appName "TextEdit"
application-use sendkey enter --appName "TextEdit"
application-use scroll C down 300 --appName "TextEdit"
```

`fill` inserts text at the target's insertion point; it does not replace the whole field or change the clipboard. With a hint it requires an AX text control and verifies that this same control actually receives text focus. OCR and icon hints cannot be used for `fill`. Omitting the hint uses the target app's focused text field, never the system's current foreground app. `scroll` accepts a pixel distance, or an explicit `--pages` value. Use an AX scroll-area hint.

For macOS Terminal, use an existing idle shell window and verify its prompt before input. `fill "command" --appName Terminal` uses background keyboard events even though Terminal's shell does not expose writable AX text attributes; the process, window and focused shell must still match. Omit the hint when the shell already has text focus. Read back the inserted command before `sendkey Return --appName Terminal`. Creating a new Terminal window can activate the app and is not part of this verified background path.

Snapshots return a private local screenshot path. View that exact window image when visual inspection is needed. `screenshot /absolute/new-file.png --appName "Name"` saves the target window image and refuses to overwrite an existing file.

## Boundaries

- `open` binds an already-running, non-hidden app. It does not launch or activate an app. Minimized or unavailable windows fail without restoration.
- Right-click, desktop-region cropping, window raising, launching new apps and closing apps are currently refused. Lifecycle and system shortcuts (quit, close, hide, minimize, app/Space switching, full-screen, Spotlight and force-quit) and window-control buttons are also refused. Closing may show a save dialog and activate the target.
- Permission checks are read-only: `doctor` reports actual runtime Accessibility and Screen Recording access. Missing access returns an error without opening settings or prompting.
- OCR and the existing CoreML model run locally on the target window image. Recognition warnings must be reported; do not claim icon recognition succeeded if the model was unavailable.
- The private session starts on demand and exits after ten minutes of inactivity. `session-stop` closes that tool session, not the target app.
- A third-party application may initiate activation itself in response to an ordinary action. Only the tested application behavior is verified; stop using a route that activates itself. Do not restore focus to conceal interference or claim universal app compatibility.

Keep normal user authorization requirements for sending, deleting, purchasing or other consequential actions. Background operation does not authorize those actions.
