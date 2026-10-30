// Sets the display of the UX VM to 1728 by 1117 points. It must run in the logged-in session.
import CoreGraphics

let display = CGMainDisplayID()
let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
let modes = CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode] ?? []
if let mode = modes.first(where: { $0.width == 1728 && $0.height == 1117 }) {
    var configuration: CGDisplayConfigRef?
    CGBeginDisplayConfiguration(&configuration)
    CGConfigureDisplayWithDisplayMode(configuration, display, mode, nil)
    CGCompleteDisplayConfiguration(configuration, .permanently)
}
