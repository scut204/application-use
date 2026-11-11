# application-use

Operate an existing macOS application window in the background through
Accessibility, isolated window screenshots, Apple Vision OCR and directed
keyboard/mouse events. The background CLI preserves the familiar
`application-use` commands while keeping the current foreground window and
physical pointer untouched by its input routes.

This fork includes a dedicated background runtime adapted from
[Open Computer Use](https://github.com/iFurySt/open-computer-use). Source,
provenance and licenses are in [`background/`](background/PROVENANCE.md).

## Build the background CLI

Requires macOS 14+, Swift 6.2 (Xcode toolchain), Python 3 and an internet
connection for the pinned libwebp build dependency. Node.js is only needed for
fixture-monitor tests. Build on the Mac architecture you intend to use.

```sh
git clone https://github.com/scut204/application-use.git
cd application-use
make background
export PATH="$PWD/build/background/scripts:$PATH"
application-use --help
application-use doctor
```

Keep the entire `build/background` directory together if moving the build:
its `scripts`, `runtime` and `licenses` directories form one installation.
`doctor` reports permissions without opening settings or requesting access.
Accessibility and Screen Recording must already be granted to the runtime;
permission setup is a manual user action.

The repository also retains its earlier Go/Swift implementation and npm
packaging. `make` and `npm install -g application-use` refer to that older
implementation; they do **not** install this background runtime. No npm package
has been published for this update. See [the legacy CLI](docs/legacy-cli.md).

## Observe, act, verify

Start with an app that is already running, visible and not minimized. `open`
binds that app; it does not launch or activate it.

```sh
application-use search TextEdit
application-use snapshot --appName TextEdit
# Use hints from the returned snapshot:
application-use click A --appName TextEdit
application-use fill B "hello" --appName TextEdit
application-use sendkey Return --appName TextEdit
application-use scroll C down 300 --appName TextEdit
application-use screenshot /absolute/new-window.png --appName TextEdit
application-use session-stop
```

The returned hints identify `AX` controls, visible `OCR` text or locally detected
`ICON` regions. Hints expire after two minutes and are checked against the same
process, window and control before input. `fill` inserts text at the insertion
point using directed keyboard events; it does not replace an entire field or
paste through the clipboard. Inspect each returned state to verify the result.

A separate cursor panel shows input feedback. It neither receives physical
mouse input nor becomes the active window. It follows the target window's
ordering and disappears when the target is lost, the session stops or the
visual idle timer expires. This source distribution uses the library's
procedural cursor drawing; extracted reference artwork is not included.

### Existing Terminal shells

First verify that an existing Terminal window has an idle shell prompt:

```sh
application-use snapshot --appName Terminal
application-use fill "pwd" --appName Terminal
# Read back the inserted command before executing it:
application-use sendkey Return --appName Terminal
```

Terminal's shell receives `sky_key` keyboard input despite its non-settable AX
text attributes. PID, window, focused control and explicit disabled/read-only
checks remain enforced. Creating a new Terminal window can activate the app;
that operation is outside this verified path.

## Recognition and boundaries

OCR uses Apple Vision locally. Optional icon recognition accepts an existing
CoreML `.mlpackage` or `.mlmodelc` via `APPLICATION_USE_MODEL`. No model is bundled
or downloaded automatically. Without a model, snapshots include a warning and
continue with AX/OCR; do not claim icon recognition succeeded. Model licenses
are separate from the runtime's MIT license.

There is no foreground mode or foreground fallback. Hidden/minimized apps,
missing permissions, window raising, app launching/closing, right-click,
desktop-region cropping, and app/window lifecycle shortcuts are refused.
A third-party app may activate itself in response to an action; compatibility
claims apply only to tested apps and observation intervals.

The private local session exits after ten minutes of inactivity.
`session-stop` stops the tool session and cursor, not the target app.
Normal authorization requirements still apply to sending, deleting, purchasing
and other consequential actions.

## Verification

```sh
make test-background
```

This runs native background/cursor policy tests, Python adapter tests and
fixture-monitor checks without driving user windows. Optional real AppKit
acceptance and demo instructions are in
[`scripts/application-use-tests/README.md`](scripts/application-use-tests/README.md).
Historical local verification and the limits of those observations are in
[`DEVLOG.md`](DEVLOG.md). This GitHub packaging update does not repeat the
previously coordinated live Terminal test.

See [runtime details](docs/background-runtime.md) and
[the agent skill](skills/application-use/SKILL.md).
