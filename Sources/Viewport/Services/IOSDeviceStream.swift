@preconcurrency import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation

/// A view-only video stream from a trusted iPhone or iPad connected over USB.
@MainActor
final class IOSDeviceStream: NSObject {
    private let sampleQueue = DispatchQueue(
        label: "com.longden.viewport.ios-device-stream",
        qos: .userInteractive
    )
    nonisolated private let frameConverter = IOSDeviceFrameConverter()
    nonisolated private let frameDelivery = LatestIOSDeviceFrameDelivery()

    private var activeSession: AVCaptureSession?
    private var activeOutput: AVCaptureVideoDataOutput?
    private var onFrame: ((CGImage) -> Void)?
    private var onFailure: ((Error) -> Void)?

    func start(
        deviceID: String,
        profile: CapturePerformanceProfile,
        onFrame: @escaping (CGImage) -> Void,
        onFailure: @escaping (Error) -> Void
    ) async throws {
        stop()

        guard await Self.requestVideoAccess() else {
            throw IOSDeviceStreamError.cameraAccessDenied
        }
        guard let device = AVCaptureDevice(uniqueID: deviceID),
              device.isConnected else {
            throw IOSDeviceStreamError.deviceDisconnected
        }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw IOSDeviceStreamError.cannotOpenDevice(error)
        }

        let session = AVCaptureSession()
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_32BGRA
        ]
        output.setSampleBufferDelegate(self, queue: sampleQueue)

        session.beginConfiguration()
        let requestedPreset = Self.capturePreset(for: profile)
        session.sessionPreset = session.canSetSessionPreset(requestedPreset)
            ? requestedPreset
            : .high
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw IOSDeviceStreamError.unsupportedDevice
        }
        session.addInput(input)
        session.addOutput(output)
        if let connection = output.connection(with: .video),
           connection.isVideoMinFrameDurationSupported {
            connection.videoMinFrameDuration = CMTime(
                value: 1,
                timescale: CMTimeScale(profile.targetFrameRate)
            )
        }
        session.commitConfiguration()

        self.onFrame = onFrame
        self.onFailure = onFailure
        activeSession = session
        activeOutput = output

        sampleQueue.async { [weak self, weak session] in
            guard let self, let session else { return }
            session.startRunning()
            if !session.isRunning {
                Task { @MainActor [weak self] in
                    guard let self, self.activeSession === session else {
                        return
                    }
                    self.fail(IOSDeviceStreamError.cannotStartCapture)
                }
            }
        }
    }

    func stop() {
        let session = activeSession
        activeSession = nil
        activeOutput = nil
        onFrame = nil
        onFailure = nil
        frameDelivery.clear()

        guard let session else { return }
        sampleQueue.async {
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    private func fail(_ error: Error) {
        let handler = onFailure
        stop()
        handler?(error)
    }

    private static func requestVideoAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            true
        case .notDetermined:
            await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            false
        @unknown default:
            false
        }
    }

    private static func capturePreset(
        for profile: CapturePerformanceProfile
    ) -> AVCaptureSession.Preset {
        switch profile {
        case .smooth:
            .hd1280x720
        case .balanced:
            .hd1920x1080
        case .sharp:
            .high
        }
    }
}

extension IOSDeviceStream: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard sampleBuffer.isValid,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let videoOutput = output as? AVCaptureVideoDataOutput else {
            return
        }

        frameDelivery.submit(output: videoOutput, pixelBuffer: pixelBuffer) {
            [frameConverter] buffer in
            frameConverter.image(from: buffer)
        } deliver: {
            @MainActor [weak self] payload in
            guard let self,
                  self.activeOutput === payload.output else {
                return
            }
            self.onFrame?(payload.image)
        }
    }
}

private enum IOSDeviceStreamError: LocalizedError {
    case cameraAccessDenied
    case deviceDisconnected
    case unsupportedDevice
    case cannotOpenDevice(Error)
    case cannotStartCapture

    var errorDescription: String? {
        switch self {
        case .cameraAccessDenied:
            "Camera access is required to view a connected iPhone."
        case .deviceDisconnected:
            "The connected iPhone is no longer available."
        case .unsupportedDevice:
            "The connected iPhone does not expose a video stream."
        case let .cannotOpenDevice(error):
            "The connected iPhone could not be opened: \(error.localizedDescription)"
        case .cannotStartCapture:
            "The connected iPhone stream could not be started."
        }
    }
}

private final class IOSDeviceFrameConverter: @unchecked Sendable {
    private let context = CIContext(options: [.cacheIntermediates: false])

    func image(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        return context.createCGImage(image, from: image.extent)
    }
}

private final class LatestIOSDeviceFrameDelivery: @unchecked Sendable {
    struct Payload: @unchecked Sendable {
        let output: AVCaptureVideoDataOutput
        let image: CGImage
    }

    private let lock = NSLock()
    private var latestOutput: AVCaptureVideoDataOutput?
    private var latestBuffer: CVPixelBuffer?
    private var deliveryIsScheduled = false

    func submit(
        output: AVCaptureVideoDataOutput,
        pixelBuffer: CVPixelBuffer,
        convert: @escaping @Sendable (CVPixelBuffer) -> CGImage?,
        deliver: @escaping @MainActor @Sendable (Payload) -> Void
    ) {
        lock.lock()
        latestOutput = output
        latestBuffer = pixelBuffer
        let shouldSchedule = !deliveryIsScheduled
        deliveryIsScheduled = true
        lock.unlock()

        guard shouldSchedule else { return }
        scheduleDelivery(convert: convert, deliver: deliver)
    }

    func clear() {
        lock.lock()
        latestOutput = nil
        latestBuffer = nil
        lock.unlock()
    }

    private func scheduleDelivery(
        convert: @escaping @Sendable (CVPixelBuffer) -> CGImage?,
        deliver: @escaping @MainActor @Sendable (Payload) -> Void
    ) {
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            self?.deliverLatest(convert: convert, deliver: deliver)
        }
    }

    private func deliverLatest(
        convert: @escaping @Sendable (CVPixelBuffer) -> CGImage?,
        deliver: @escaping @MainActor @Sendable (Payload) -> Void
    ) {
        lock.lock()
        let output = latestOutput
        let buffer = latestBuffer
        latestOutput = nil
        latestBuffer = nil
        lock.unlock()

        if let output, let buffer, let image = convert(buffer) {
            Task { @MainActor in
                deliver(Payload(output: output, image: image))
            }
        }

        lock.lock()
        let hasAnotherFrame = latestBuffer != nil
        if !hasAnotherFrame {
            deliveryIsScheduled = false
        }
        lock.unlock()

        if hasAnotherFrame {
            scheduleDelivery(convert: convert, deliver: deliver)
        }
    }
}
