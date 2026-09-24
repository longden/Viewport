# Third-party notices

Viewport is licensed under the Apache License, Version 2.0. See
[`LICENSE`](LICENSE). This file is the attribution notice for third-party
material included in or used by Viewport.

Apache 2.0 is compatible with the MIT-licensed idb excerpts below. Those
excerpts remain MIT; they are not relicensed as Apache 2.0.

## Meta idb (MIT)

`Sources/IndigoTouch/Indigo.h`, `Sources/IndigoTouch/Mach.h`, and HID message
construction in `Sources/IndigoTouch/ViewportIndigoTouch.m` are adapted from
[Meta idb](https://github.com/facebook/idb)
(`PrivateHeaders/SimulatorApp/` and `FBSimulatorIndigoHID.m`), copyright Meta
Platforms, Inc. and affiliates, under the MIT License:

```
MIT License

Copyright (c) Meta Platforms, Inc. and affiliates.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## vscode-ios-simulator-embed (Apache 2.0)

The IndigoTouch module layout and SimulatorKit HID session flow are adapted
from [vscode-ios-simulator-embed](https://github.com/mkloouo/vscode-ios-simulator-embed)
(`native/ios-sim-helper`), copyright 2026 Mykola Odnosumov, licensed under the
Apache License 2.0. That helper also attributes Meta idb (MIT), as above.

Viewport’s original capture, workspace, and Android code is separate from that
project.

## scrcpy (Apache 2.0)

Viewport does **not** vendor or redistribute
[scrcpy](https://github.com/Genymobile/scrcpy) (copyright Genymobile and
Romain Vimont, Apache License 2.0). If scrcpy is installed on the Mac,
Viewport may launch that install’s `scrcpy-server` on a device and speak
scrcpy’s video/control socket protocol. Install it yourself with
`brew install scrcpy` if you want that transport.

## simslim (MIT)

Viewport does **not** vendor or redistribute
[simslim](https://github.com/MobAI-App/simslim) (copyright Interlap, MIT
License). If simslim is installed on the Mac, Viewport may invoke that
install’s `simslim` CLI to slim or restore an iOS Simulator (Light Sim).
Install it yourself with `brew install mobai-app/tap/simslim` or from the
Play menu’s **Install Light Sim…** button.

## Apple private frameworks

At runtime the IndigoTouch module loads Apple’s private CoreSimulator and
SimulatorKit frameworks from Xcode (`Contents/SharedFrameworks` or
`Library/PrivateFrameworks`, whichever is present). These interfaces are
undocumented and can change between Xcode releases. Frame delivery follows
the idb framebuffer-consumer approach (`SimDevice` IO ports → IOSurface /
damage callbacks), not Simulator.app window embedding.
