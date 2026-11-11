# Background acceptance probe

This directory independently checks the application-use wrapper with a real
AppKit receiver. It does not use `FixtureBridge` or synthetic OCU snapshots.

Compile and run the pure evidence-classification tests without launching GUI:

```sh
node scripts/application-use-tests/run-background.mjs
node --test scripts/application-use-tests/verification.test.mjs
```

After the runtime is built and has existing Accessibility and Screen Recording
permission, explicitly run the live acceptance test:

```sh
node scripts/application-use-tests/run-background.mjs --run \
  --cli scripts/application-use/application_use.py \
  --runtime /absolute/path/to/ApplicationUseBackground
```

The runtime path is a caller-supplied build artifact, not a repository default.
The runner prints a temporary report directory and retains JSON evidence. It
uses a separate `APPLICATION_USE_SESSION` so hints do not overlap normal work.
It never grants permissions or opens permission settings.
The matching private daemon is shut down through the wrapper's hidden
`_shutdown` command before ending the observed interval.

## What is observed

- A normal key-capable AppKit window starts with `orderBack`, without activating
  an application or changing an existing window. App launch completes with no
  windows and a prohibited activation policy; only the next event-loop turn
  switches to accessory and creates the test window, avoiding AppKit's initial
  activation of a pre-existing window. No deactivate/restore workaround is used.
  Its button, text view and
  scroll view publish only fixture-owned state. It has a unique bundle identity
  and does not match the upstream test bridge.
- The current foreground application is the sentinel. The read-only monitor
  starts before fixture launch and combines application activation notifications,
  AX focused/main-window notifications, 10 ms pointer/PID sampling, and 50 ms
  focused-window sampling. Window identity is compared in memory; no user window
  titles, content, keystrokes, or screenshots are recorded by the monitor.
- Snapshot, screenshot, click, fill, sendkey, scroll and rejected right-click
  exercise the application-use CLI. Each successful action must also change the
  real receiver state as expected. Negative checks require a fill targeting a
  button to fail before clicking or typing, and require app/window-management
  keyboard shortcuts (including modifier aliases) to fail without changing the
  receiver or its window.
- The receiver starts inside the sentinel's existing window geometry when that
  window is large enough. Window ordering and containment must show complete
  occlusion before and after a screenshot. The screenshot must contain the
  receiver's distinctive color marker and is deleted after successful checks.
  Failed captures are retained in the report directory with color/alpha
  diagnostics and the receiver's draw count. The backing store is explicitly
  drawn while the window remains behind the sentinel. ImageIO decodes the
  embedded display ICC profile, and CoreGraphics converts once to sRGB before
  marker sampling; `NSBitmapImageRep.colorAt` is not used because it can lose
  that profile through calibrated RGB. No
  user window is moved to create an occlusion case.
- The runner kills only process handles it created. It never restores focus,
  moves the pointer, sends independent test input, or terminates an application
  by name.

## Interpretation and limits

`passed` means actions reached real AppKit controls and the observed interval
contained no detected foreground/window/pointer change. A window notification
is retained even when a subsequent read has already returned to the original
window. Polling gaps over 150 ms, missing focus coverage, and failed AX reads
cannot produce a pass.

Any desktop activity produces `inconclusive-desktop-activity`. A user moving the
mouse or changing a window cannot reliably be distinguished from automation by
these passive observations. Such an interval must not be reported as either a
clean pass or proven automation-caused interference.

This does not prove an absence of arbitrarily brief pointer movements between
samples, nor does it certify every Electron/WebKit/custom application. Target
local key-window state can change during directed keyboard delivery; the
sentinel's global foreground/window state must remain unchanged. If the current
foreground window is too small to cover the receiver, the occlusion check fails
with a coverage explanation instead of rearranging the desktop. Launching GUI
is opt-in (`--run`); compile-only success is not GUI acceptance.

## Visible demonstration

The separate `--demo` mode preserves the original occluded acceptance path and
its thresholds. Without `--run`, it only compiles the fixture and recorder:

```sh
node scripts/application-use-tests/run-background.mjs --demo
```

Explicitly run a visible demonstration with a runtime that reports
`visualCursorEnabled: true` and its actual `runtimePID` from `doctor`:

```sh
node scripts/application-use-tests/run-background.mjs --demo --run \
  --cli scripts/application-use/application_use.py \
  --runtime /absolute/path/to/ApplicationUseBackground \
  --output /absolute/new-path/cursor-demo.gif
```

After nonactivating startup, the fixture shows its own normal window at the
screen's right side with `orderFront`, without activating it or moving another
window. Five real CLI operations move between left, right, text and lower
targets, with short pauses. Receiver state must verify each click or insertion.
The demonstration usually takes 18–25 seconds, then closes only its own
fixture and private runtime session. The same foreground/window/pointer
monitor remains active throughout; user input still makes the stability result
inconclusive.

`WindowDemoRecorder.swift` samples the exact fixture backing store and the one
visible window named `Application Use Cursor` owned by the reported runtime
PID. It verifies window ownership on every frame. The recorder never captures
a display or screen rectangle: it composites these two real captured images
by their WindowServer bounds onto a neutral canvas. Areas outside the fixture
and real overlay contain only that neutral background, including during the
cursor's initial arrival. No cursor artwork or motion is reconstructed.
Missing/ambiguous window identity fails the recording; there is no desktop
capture fallback.

The GIF must contain at least five actual overlay captures and at least 30
points of observed window movement. An adjacent `.gif.json` records frame
counts, the two process/window identities and the actual overlay trajectory.
The demo prints a compact result with the GIF and detailed-report paths.
After recording has finalized, the runner closes only its fixture, keeps the
runtime alive, waits 350 ms and checks that no visible cursor window remains.
Only after that target-loss check does it stop the private runtime session.
