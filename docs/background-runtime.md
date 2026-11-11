# Background runtime

## Layout

- `background/`: independently buildable Swift package and source attribution.
- `background/apps/ApplicationUseBackground/`: JSON-line server, permission
  queries and window-only OCR/CoreML recognizer.
- `background/packages/`: adapted Open Computer Use core and required native
  modules. Its MIT license applies separately from the older CLI metadata.
- `scripts/application-use/`: Python standard-library adapter, portable launcher
  and adapter tests.
- `scripts/application-use-tests/`: opt-in real AppKit fixture, passive monitor
  and isolated-window recorder. See that directory's README before running GUI
  acceptance.
- `build/background/`: generated runtime, launcher, adapter and licenses.

`make background` builds and stages files locally. It does not install services,
modify the user's active skills or MCP configuration, request permissions, or
launch user apps. Add `build/background/scripts` to PATH to select this version.
The launcher also works through a symlink. `APPLICATION_USE_RUNTIME` may select
a separately built executable; no legacy executable is used automatically.

The Python adapter starts a private native session on demand. Unix socket and
session directory permissions restrict it to the current user. Snapshots retain
process/window identity; hints are revalidated and expire after two minutes.
An input error invalidates hints rather than automatically replaying an action.
Native stderr is not persisted because it can contain input text.

## Targeted input

Mouse and keyboard input use `sky_click` and `sky_key`. The directed event path
uses private SkyLight behavior and public CoreGraphics event delivery; it must
be tested on each relevant macOS/application combination. It does not create a
second system pointer or a separate macOS login session.

Terminal support is intentionally narrow: the real Terminal bundle, shell text
area, process, window, expected element and current text focus must all match.
Other controls still require a writable AX text attribute. Existing Terminal
shell input was verified in a coordinated local test; opening a new window is
not covered by that result.

## Recognition

Apple Vision processes only the target window image. Set
`APPLICATION_USE_MODEL=/absolute/path/to/model.mlpackage` (or `.mlmodelc`) to opt
into local CoreML icon recognition using a model you already have rights to
use. The repository does not redistribute an icon model. Missing model warnings
are part of the snapshot output and must not be hidden.

## Checks and evidence

Run `make test-background` for policy, adapter and monitor unit checks, and
`make background` for a release build. The GUI runner compiles fixtures without
launching them unless `--run` is explicitly provided.

The prior local Terminal verification observed 6,134 samples over about 61.43
seconds with no detected foreground app, foreground window or physical pointer
change while an existing shell received and executed the marker command.
Two earlier intervals contained desktop activity and were inconclusive; neither
sent text. These historical results do not certify every app, future macOS
versions, or disturbances shorter than the monitoring interval. The source
package uses procedural cursor artwork, rather than the reference image used
in that earlier installation. This packaging task does not repeat GUI testing.
