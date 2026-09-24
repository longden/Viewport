# AGENTS.md

Native macOS SwiftUI app via SwiftPM (macOS 26+, Swift 5 language mode). Human overview: [`README.md`](README.md).

## Commands

Prefer `--disable-sandbox` for SwiftPM. Do not change the Mac’s global `xcode-select`; set `DEVELOPER_DIR` for commands that need Xcode's toolchain.

```sh
./script/package.sh                    # unsigned zip/dmg from dist/
xcrun swift build --disable-sandbox
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --disable-sandbox
```

## Layout

- `Sources/Viewport/` — App, Models, Stores, Services, Views, Support
- `Sources/IndigoTouch/` — ObjC SimulatorKit HID / surface bridge (see [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md))
- `Tests/ViewportTests/` — unit tests; no UI harness
- `script/` — `package.sh`
- `dist/` — generated `.app`; gitignored, do not hand-edit

## Capture

- Streams live in panes. Do not embed Simulator.app views. Fallback order belongs in `CaptureTransportPolicy`, not the UI.
- Taps: aspect-fit into top-left normalized `0…1` of the *displayed* frame (`DevicePreviewInputGeometry`). Surface, screencap, gRPC, scrcpy, and USB frames need no chrome crop. Host-window (ScreenCaptureKit) frames do, before input.
- Mid-session failures continue remaining strategies for the current mode. Do not jump to polling unless nothing else remains.
- USB iPhone/iPad is view-only: no HID, deep link, push, or log injection.
- Device logs stay in bounded in-memory buffers. Never auto-persist them.

## Conventions

- `@MainActor` for UI, stores, and stream orchestration. Mark `stop()`-style teardown `nonisolated` when it must run from `deinit`.
- Prefer small types under `Services/` or `Models/`. Do not grow mega-views.
- Keep versions in sync: `Package.swift` header and `script/package.sh`.
- Match surrounding Swift. No drive-by refactors. No new markdown unless asked.
- Capture, input geometry, or transport changes need tests under `Tests/ViewportTests/`.
