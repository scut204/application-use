# Background runtime provenance

This is a local adaptation of Open Computer Use, not an official upstream
release. The copied core and native shims originate from:

- Source: https://github.com/iFurySt/open-computer-use
- Revision: `1263960a888e77297e551b560206bd44fd1b53e5`
- License: [MIT](LICENSE)
- Embedded Cua Driver, yabai and libwebp notices: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)

The dedicated `ApplicationUseBackground` entrypoint, Python adapter and policy
tests were added for this fork. Changes to the copied core remove activation,
window raising/moving and global pointer fallback paths; require exact live
process/window ownership; validate editable focus before each text chunk; and
scope the nonactivating cursor to the target window. Terminal support only
accepts the real `com.apple.Terminal` bundle's `AXTextArea` described as `shell`
when ordinary AX text attributes are not writable. Explicit disabled/read-only
flags and focus mismatch continue to reject input.

The Swift package includes the shared core's native support modules to keep
its source dependencies buildable. The dedicated executable does not expose
the upstream management, lock-screen, permission onboarding or virtual-display
entrypoints. Only the dedicated background executable is built and staged by
`make background`.

The package pins libwebp-Xcode 1.6.0 in `Package.resolved`. No compiled runtime,
user screenshots, raw live-test logs, icon model, extracted proprietary app
bundle or reference cursor artwork is committed. With no reference image, the
existing MIT-licensed library renderer draws the cursor procedurally.
