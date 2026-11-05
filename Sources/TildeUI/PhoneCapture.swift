import AVFoundation
import CoreMediaIO
import VideoToolbox

/// An iPhone connected by cable, whose screen macOS offers as a capture device.
struct Phone: Equatable, Sendable {
    /// The capture device's unique ID.
    let id: String
    let name: String
}

/// Finds iPhones connected by cable and takes pictures of their screens. The phone must be
/// unlocked and trust this Mac; Tilde needs the camera permission.
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

    static func device(for phone: Phone) -> AVCaptureDevice? {
        devices().first { $0.uniqueID == phone.id }
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

    /// One frame of the phone's screen, or nil when it sends none within two seconds.
    static func snapshot(of phone: Phone) async -> CGImage? {
        guard await isAllowed(), let device = device(for: phone), let input = try? AVCaptureDeviceInput(device: device) else {
            return nil
        }
        let session = AVCaptureSession()
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        guard session.canAddInput(input), session.canAddOutput(output) else {
            return nil
        }
        session.addInput(input)
        session.addOutput(output)

        let grabber = FrameGrabber()
        output.setSampleBufferDelegate(grabber, queue: grabber.queue)
        session.startRunning()
        defer { session.stopRunning() }
        return await grabber.firstFrame(timeout: .seconds(2))
    }

    private static func devices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .muxed, position: .unspecified).devices
    }
}

/// Hands out the first frame a capture session sends.
private final class FrameGrabber: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "dev.tilde.phone-snapshot")
    // Read and written on `queue` only.
    private var continuation: CheckedContinuation<CGImage?, Never>?

    func firstFrame(timeout: Duration) async -> CGImage? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                self.continuation = continuation
            }
            queue.asyncAfter(deadline: .now() + Double(timeout.components.seconds)) { [self] in
                finish(with: nil)
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput buffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let frame = buffer.imageBuffer else {
            return
        }
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(frame, options: nil, imageOut: &image)
        finish(with: image)
    }

    private func finish(with image: CGImage?) {
        continuation?.resume(returning: image)
        continuation = nil
    }
}
