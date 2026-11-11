# 2026-11-11 — Package background application-use source for GitHub

The user requested that the locally tested application-use changes be uploaded
to the existing `scut204/application-use` repository.

Added an independent Swift package containing the adapted Open Computer Use
core, dedicated JSON-line entrypoint and AX/OCR/CoreML recognition code, plus a
portable Python CLI, policy tests and optional AppKit fixture harness. The
background entrypoint retains strict process/window/focus validation and
supports an existing macOS Terminal shell through directed keyboard events.

Added `make background` and `make test-background`, source-build instructions,
agent guidance, development records and upstream licenses/provenance. The
existing Go/Swift CLI and npm packaging remain available as the legacy build.
The new source uses procedural cursor drawing and excludes reference artwork,
optional model weights, compiled binaries and private acceptance logs.

Validation: release build passed, 25 native policy tests passed, 36 Python
adapter tests passed and 4 fixture-monitor tests passed. Staged launcher help,
shell syntax and diff whitespace checks passed. The prior live Terminal result
is documented as historical evidence; no GUI acceptance was repeated for this
source packaging task.
