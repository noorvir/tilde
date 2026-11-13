import AppKit

extension NSApplication {
    /// A titled window of Tilde closes, such as Settings or the browser. Tilde stays in the
    /// Dock, with its menus, while another one shows; else it is a menu bar app again.
    func titledWindowWillClose(_ closing: NSWindow?) {
        let showsAnother = windows.contains { $0 !== closing && $0.isVisible && $0.styleMask.contains(.titled) }
        if !showsAnother {
            setActivationPolicy(.accessory)
        }
    }
}
