import AppKit
import CoreImage

/// The screen under the wireframe's components, blurred: a view under the canvas's page that
/// shows one picture of the screen under the canvas, blurred, only inside the components'
/// shapes. The page fades and fills over it. The picture is blurred once for each picture and
/// radius; a move of the shapes changes only the mask.
@MainActor
final class UnderBlurView: NSView {
    struct Shape: Equatable {
        /// In points from the top left of the view.
        let rect: CGRect
        let isEllipse: Bool
    }

    /// The blur's radius, in points; 0 shows nothing.
    var radius = 0.0 {
        didSet {
            if radius != oldValue {
                blurAgain()
            }
        }
    }
    var shapes: [Shape] = [] {
        didSet {
            if shapes != oldValue {
                updateMask()
            }
        }
    }
    /// The screen under the view, not blurred, at one pixel per point; nil before the first.
    private(set) var picture: CGImage?
    private let imageLayer = CALayer()
    private let mask = CAShapeLayer()
    private static let context = CIContext()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        imageLayer.contentsGravity = .resize
        imageLayer.mask = mask
        imageLayer.isHidden = true
        layer?.addSublayer(imageLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Clicks go to the page over it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func layout() {
        super.layout()
        withoutAnimation {
            imageLayer.frame = bounds
            mask.frame = bounds
        }
        updateMask()
    }

    /// The screen under the view, as large as it, at any scale.
    func show(_ screen: CGImage) {
        picture = Self.picture(of: screen, size: bounds.size)
        blurAgain()
    }

    /// `screen` at one pixel per point of `size`: a blur needs no more, and takes a quarter of
    /// the time at two pixels per point.
    static func picture(of screen: CGImage, size: CGSize) -> CGImage? {
        let points = CIImage(cgImage: screen).transformed(by: CGAffineTransform(scaleX: size.width / CGFloat(screen.width), y: size.height / CGFloat(screen.height)))
        return context.createCGImage(points, from: points.extent)
    }

    /// Lets go of the picture: the screen under the view will have changed.
    func forget() {
        picture = nil
        blurAgain()
    }

    private func blurAgain() {
        guard let picture, radius > 0 else {
            withoutAnimation {
                imageLayer.contents = nil
                imageLayer.isHidden = true
            }
            return
        }
        let blurred = Self.blurred(picture, radius: radius)
        withoutAnimation {
            imageLayer.contents = blurred
            imageLayer.isHidden = false
        }
    }

    /// `picture` blurred with a Gaussian of `radius` pixels, its edges kept sharp.
    static func blurred(_ picture: CGImage, radius: Double) -> CGImage? {
        let image = CIImage(cgImage: picture)
        let blurred = image.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: image.extent)
        return context.createCGImage(blurred, from: image.extent)
    }

    /// The outline of all `shapes` in a space of this height with its origin at the bottom left,
    /// as a layer's or a bitmap's.
    static func path(of shapes: [Shape], height: CGFloat) -> CGPath {
        let path = CGMutablePath()
        for shape in shapes {
            let rect = CGRect(x: shape.rect.minX, y: height - shape.rect.maxY, width: shape.rect.width, height: shape.rect.height)
            if shape.isEllipse {
                path.addEllipse(in: rect)
            } else {
                path.addRect(rect)
            }
        }
        return path
    }

    private func updateMask() {
        withoutAnimation {
            mask.path = Self.path(of: shapes, height: bounds.height)
        }
    }

    private func withoutAnimation(_ change: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        change()
        CATransaction.commit()
    }
}
