import AppKit
import os
import ScreenCaptureKit

/// Captures part of the screen or of one window as PNG. Tilde's own windows never appear in
/// a capture, except Tilde's browser when it is the window being annotated.
enum ScreenCapture {
    static var isAllowed: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Captures `rect` of the screen (Quartz coordinates) without Tilde's windows, except the
    /// ones in `keeping`. When `outline` is given, the image gets a blue outline around that
    /// rect so the agent sees which element was meant. The long side is at most `maxSide`
    /// pixels. Returns nil when Screen Recording is not allowed or the capture fails.
    static func png(of rect: CGRect, outline: CGRect?, keeping ownWindowIDs: Set<CGWindowID>, maxSide: Double) async -> Data? {
        guard isAllowed else {
            return nil
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let center = CGPoint(x: rect.midX, y: rect.midY)
            guard let display = content.displays.first(where: { $0.frame.contains(center) }) ?? content.displays.first else {
                return nil
            }

            let tilde = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let kept = content.windows.filter { ownWindowIDs.contains($0.windowID) }
            let filter = SCContentFilter(display: display, excludingApplications: tilde, exceptingWindows: kept)

            let area = rect.intersection(display.frame)
            guard !area.isNull, area.width >= 1, area.height >= 1 else {
                return nil
            }

            let scale = CGFloat(filter.pointPixelScale)
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = area.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
            configuration.width = Int(area.width * scale)
            configuration.height = Int(area.height * scale)
            configuration.showsCursor = false
            configuration.captureResolution = .best

            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            return png(from: image, outline: outline.map { $0.offsetBy(dx: -area.minX, dy: -area.minY) }, scale: scale, maxSide: maxSide)
        } catch {
            Logger(subsystem: "dev.tilde.app", category: "capture").error("screen capture failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Captures `area` of one window without the windows in front of it, with a blue outline
    /// around `outline`. Both rects are Quartz coordinates. The long side is at most `maxSide`
    /// pixels.
    static func png(ofWindow windowID: CGWindowID, area: CGRect, outline: CGRect, maxSide: Double) async -> Data? {
        guard isAllowed else {
            return nil
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                return nil
            }

            let area = area.intersection(window.frame)
            guard !area.isNull, area.width >= 1, area.height >= 1 else {
                return nil
            }

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let scale = CGFloat(filter.pointPixelScale)
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = area.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
            configuration.width = Int(area.width * scale)
            configuration.height = Int(area.height * scale)
            configuration.ignoreShadowsSingleWindow = true
            configuration.showsCursor = false
            configuration.captureResolution = .best

            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            let box = outline.offsetBy(dx: -area.minX, dy: -area.minY)
            return png(from: image, outline: box, scale: scale, maxSide: maxSide)
        } catch {
            Logger(subsystem: "dev.tilde.app", category: "capture").error("window capture failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Draws the optional outline (rect in points, relative to the image), limits the long
    /// side to `maxSide` px and encodes PNG. `scale` is image pixels per point.
    static func png(from image: CGImage, outline: CGRect?, scale: CGFloat, maxSide: Double) -> Data? {
        let factor = min(1, maxSide / Double(max(image.width, image.height)))
        let width = Int(Double(image.width) * factor)
        let height = Int(Double(image.height) * factor)

        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        context.interpolationQuality = .high
        context.draw(image, in: canvas)

        if let outline {
            let pixels = scale * factor
            // CGContext has a bottom-left origin; the outline rect is top-left based.
            let box = CGRect(
                x: outline.minX * pixels,
                y: CGFloat(height) - outline.maxY * pixels,
                width: outline.width * pixels,
                height: outline.height * pixels
            ).insetBy(dx: -2 * pixels, dy: -2 * pixels)
            context.setStrokeColor(NSColor.tildeBlue.cgColor)
            context.setLineWidth(2 * pixels)
            context.addPath(CGPath(roundedRect: box, cornerWidth: 4 * pixels, cornerHeight: 4 * pixels, transform: nil))
            context.strokePath()
        }

        guard let result = context.makeImage() else {
            return nil
        }
        return NSBitmapImageRep(cgImage: result).representation(using: .png, properties: [:])
    }
}
