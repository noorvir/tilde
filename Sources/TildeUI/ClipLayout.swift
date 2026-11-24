import CoreGraphics

/// Where a saved video's parts go on its 16:9 canvas, in fractions of the canvas with a
/// top-left origin, so the preview and the export place them alike at any size.
struct ClipLayout: Equatable {
    var background: VideoBackground
    /// The screen clip's centre.
    var screenCenter = CGPoint(x: 0.5, y: 0.5)
    /// 1 fits the clip to the canvas.
    var screenScale: CGFloat = 0.86
    /// The camera's centre; nil for a clip without a camera.
    var cameraCenter: CGPoint?
    /// The camera's side, in fractions of the canvas height.
    var cameraSide: CGFloat = 0.28
    var cameraShape = CameraBubble.Shape.circle

    static let aspect: CGFloat = 16 / 9

    /// The screen clip's and the camera's frames on a canvas of `canvas` size, top-left origin.
    func frames(in canvas: CGSize, clip: CGSize) -> (screen: CGRect, camera: CGRect?) {
        let fit = min(canvas.width / max(clip.width, 1), canvas.height / max(clip.height, 1)) * screenScale
        let size = CGSize(width: clip.width * fit, height: clip.height * fit)
        let screen = CGRect(
            x: screenCenter.x * canvas.width - size.width / 2, y: screenCenter.y * canvas.height - size.height / 2, width: size.width, height: size.height
        )
        guard let cameraCenter else {
            return (screen, nil)
        }
        let side = cameraSide * canvas.height
        let camera = CGRect(x: cameraCenter.x * canvas.width - side / 2, y: cameraCenter.y * canvas.height - side / 2, width: side, height: side)
        return (screen, camera)
    }
}
