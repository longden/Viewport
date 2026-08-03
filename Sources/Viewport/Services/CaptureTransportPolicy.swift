@MainActor
protocol DeviceStream: AnyObject {
    func stop()
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

extension HostWindowStream: DeviceStream {}
extension ScrcpyDeviceStream: DeviceStream {}
extension IOSDeviceStream: DeviceStream {}
extension IOSSimulatorSurfaceStream: DeviceStream {}
extension AndroidEmulatorGrpcStream: DeviceStream {}
