import AVFoundation
import CoreMediaIO
import VideoToolbox

/// An iPhone connected by cable, whose screen macOS offers as a capture device.
struct Phone: Equatable, Sendable {
    /// The capture device's unique ID.
    let id: String
    let name: String
}

/// Finds iPhones connected by cable, and captures their screens for recordings. The phone must be unlocked and trust this Mac; Tilde needs the camera
/// permission.
enum PhoneCapture {
    /// Lets macOS offer the screens of iPhones and iPads on a cable as capture devices. They
    /// appear a moment after the first call.
    static func allowPhones() {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var allow: UInt32 = 1
        CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &allow)
    }

    /// The phones on a cable now.
    static func phones() -> [Phone] {
        devices().map { Phone(id: $0.uniqueID, name: $0.localizedName) }
    }

    /// Whether Tilde may film phones already, without asking.
    static var hasCameraAccess: Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    /// Whether Tilde may record the phone, asking the user the first time.
    static func isAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        default:
            return false
        }
    }

    /// A capture session of the phone's screen as BGRA frames, not running yet, with its
    /// device and its output.
    static func session(for phone: Phone) async throws -> (session: AVCaptureSession, device: AVCaptureDevice, output: AVCaptureVideoDataOutput) {
        guard await isAllowed() else {
            throw ScreenRecorder.Failure.notAllowed
        }
        guard let device = devices().first(where: { $0.uniqueID == phone.id }) else {
            throw ScreenRecorder.Failure.noSource
        }
        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        guard session.canAddInput(input), session.canAddOutput(output) else {
            throw ScreenRecorder.Failure.noSource
        }
        session.addInput(input)
        session.addOutput(output)
        return (session, device, output)
    }

    private static func devices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .muxed, position: .unspecified).devices
    }
}

/// Waits for a capture session's first frame: a phone's format says 0 × 0 until it streams,
/// so the first frame gives its size.
final class FirstFrame: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "dev.tilde.first-frame")
    // Read and written on `queue` only.
    private var waiting: CheckedContinuation<CGImage, Error>?

    /// The first frame; `Failure.noFrames` when none comes in time.
    func image(timeout seconds: TimeInterval) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                waiting = continuation
                queue.asyncAfter(deadline: .now() + seconds) { [self] in
                    finish(with: .failure(ScreenRecorder.Failure.noFrames))
                }
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput buffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        var image: CGImage?
        if let frame = buffer.imageBuffer {
            VTCreateCGImageFromCVPixelBuffer(frame, options: nil, imageOut: &image)
        }
        if let image {
            finish(with: .success(image))
        }
    }

    /// Runs on `queue`; only the first result counts.
    private func finish(with result: Result<CGImage, Error>) {
        waiting?.resume(with: result)
        waiting = nil
    }
}
