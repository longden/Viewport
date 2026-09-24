<p align="center">
  <img src="icon.png" width="128" alt="Viewport icon">
</p>

# Viewport

A native macOS workspace for comparing web, Android, and iOS side by side.

Viewport streams a live webpage, an Android emulator (or connected phone), and an iOS Simulator (or connected iPhone) into one window. Tap, type, and drive the visible devices together. Screenshots, recordings, and logs stay in the app.

![Viewport workspace](screenshot.png)

## Features

- **Web, Android, and iOS panes** in one window — show or hide each from the toolbar
- **Live capture** — Simulator framebuffer, Android gRPC, or scrcpy by default, with a Legacy window-capture fallback if a stream drops
- **Light Sim** — optional slimmer iOS Simulator via [simslim](https://github.com/MobAI-App/simslim); install from Help or the iOS Play menu
- **Device input** — touch, keyboard, clipboard, deep links, location, and optional mirroring across panes
- **Build & Play** — install an Xcode or Android project onto the visible simulators and emulators
- **Workspace capture** — annotated screenshots, MP4 recording, and a developer console for web, logcat, and simulator logs
- **Connected iPhone and iPad are view-only** — no touch, keyboard, deep links, or device logs

## Build from source

```sh
xcrun swift build --disable-sandbox
```

Requires macOS 26+ and Xcode. Android also needs the SDK (`brew install scrcpy` for a connected phone). Light Sim needs `brew install mobai-app/tap/simslim`.

## License

Copyright 2026 Longden. Viewport is licensed under the [Apache License 2.0](LICENSE). Third-party notices are in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
