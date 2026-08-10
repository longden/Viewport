# AGENTS.md

Native macOS SwiftUI app via SwiftPM (macOS 26+, Swift 5 language mode). Human overview: [`README.md`](README.md).

## Commands

Prefer `--disable-sandbox` for SwiftPM. Do not change the Mac’s global `xcode-select`; scripts set `DEVELOPER_DIR` to `/Applications/Xcode.app` when present.

```sh
./script/build_and_run.sh              # build, package dist/Viewport.app, launch
./script/build_and_run.sh --debug
./script/build_and_run.sh --launch     # existing dist/ app
./script/build_and_run.sh --build-only
./script/package.sh                    # unsigned zip/dmg from dist/
xcrun swift build --disable-sandbox
xcrun swift test --disable-sandbox
```

A Cursor stop hook rebuilds and launches after edits under `Sources/`, `Tests/`, `Package.swift`, `script/`, or `AppIcon.icon`.

## Layout

- `Sources/Viewport/` — App, Models, Stores, Services, Views, Support
- `Sources/IndigoTouch/` — ObjC SimulatorKit HID / surface bridge (see [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md))
- `Tests/ViewportTests/` — unit tests; no UI harness
- `script/` — `build_and_run.sh`, `package.sh`
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
- Keep versions in sync: `Package.swift` header, `script/build_and_run.sh` (`APP_VERSION`), `script/package.sh`.
- Match surrounding Swift. No drive-by refactors. No new markdown unless asked.
- Capture, input geometry, or transport changes need tests under `Tests/ViewportTests/`.
