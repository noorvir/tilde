import ApplicationServices

extension AXUIElement {
    /// The value of an attribute, or nil when the element has none of this type.
    func attribute<T>(_ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success, let value else {
            return nil
        }
        // AXUIElement and AXValue are CF types, which `as?` does not check.
        if T.self == AXUIElement.self {
            return CFGetTypeID(value) == AXUIElementGetTypeID() ? (value as! T) : nil
        }
        if T.self == AXValue.self {
            return CFGetTypeID(value) == AXValueGetTypeID() ? (value as! T) : nil
        }
        if T.self == [AXUIElement].self {
            return (value as? [AXUIElement]) as? T
        }
        return value as? T
    }

    /// The element's frame in Quartz screen coordinates.
    var frame: CGRect? {
        guard let position: AXValue = attribute(kAXPositionAttribute), let size: AXValue = attribute(kAXSizeAttribute) else {
            return nil
        }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &origin), AXValueGetValue(size, .cgSize, &extent) else {
            return nil
        }
        return CGRect(origin: origin, size: extent)
    }
}
