import AppKit

/// A screenshot as an image, for a view that shows it. The image is made once for each
/// picture: a view body that made it would decode the picture again on each redraw. A view
/// keeps it as a `@StateObject`, so it goes with the view.
@MainActor
final class DecodedImage: ObservableObject {
    private var data: Data?
    private var image: NSImage?

    /// The image of `data`: the same one for as long as the data is the same.
    func image(of data: Data?) -> NSImage? {
        if data != self.data {
            self.data = data
            image = data.flatMap { NSImage(data: $0) }
        }
        return image
    }
}
