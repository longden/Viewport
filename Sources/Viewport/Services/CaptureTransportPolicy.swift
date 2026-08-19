@MainActor
protocol DeviceStream: AnyObject {
    /// Safe to call from any isolation domain, including `deinit`.
    nonisolated func stop()
}

enum CaptureStrategy: Equatable {
    case simulatorSurface
    case emulatorGrpc
    case hostWindow
    case scrcpy
    case polling
    case usbDevice
}

enum CaptureTransportPolicy {
    /// True when a live stream is already on the preferred transport for this
    /// mode, so Refresh should not tear it down to recover sticky fallbacks.
    static func shouldKeepLiveStream(
        transport: CaptureTransport,
        mode: CaptureMode,
        deviceKind: StreamedDeviceKind
    ) -> Bool {
        switch transport {
        case .screencap:
            false
        case .simulatorSurface, .usbDevice, .scrcpy, .windowStream, .emulatorGrpc:
            strategies(mode: mode, deviceKind: deviceKind).first?
                .matches(transport) == true
        }
    }

    static func strategies(
        mode: CaptureMode,
        deviceKind: StreamedDeviceKind
    ) -> [CaptureStrategy] {
        switch (mode, deviceKind) {
        case (_, .iOSDevice):
            [.usbDevice]
        case (.direct, .iOSSimulator):
            [.simulatorSurface, .hostWindow, .polling]
        case (.direct, .androidEmulator):
            [.emulatorGrpc, .hostWindow, .scrcpy, .polling]
        case (_, .androidDevice):
            [.scrcpy, .polling]
        case (.classic, .iOSSimulator):
            [.hostWindow, .polling]
        case (.classic, .androidEmulator):
            [.hostWindow, .scrcpy, .polling]
        }
    }
}

extension CaptureStrategy {
    func matches(_ transport: CaptureTransport) -> Bool {
        switch (self, transport) {
        case (.simulatorSurface, .simulatorSurface),
             (.usbDevice, .usbDevice),
             (.polling, .screencap):
            true
        case (.emulatorGrpc, .emulatorGrpc):
            true
        case (.hostWindow, .windowStream):
            true
        case (.scrcpy, .scrcpy):
            true
        default:
            false
        }
    }
}

extension HostWindowStream: DeviceStream {}
extension ScrcpyDeviceStream: DeviceStream {}
extension IOSDeviceStream: DeviceStream {}
extension IOSSimulatorSurfaceStream: DeviceStream {}
extension AndroidEmulatorGrpcStream: DeviceStream {}
