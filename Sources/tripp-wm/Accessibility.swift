import AppKit
import ApplicationServices
import TrippWMCore

/// Private but stable since macOS 10.9; every macOS window manager uses it
/// to match Accessibility windows with window server IDs.
@_silgen_name("_AXUIElementGetWindow")
private func axWindowID(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

extension AXUIElement: WindowFrameBackend, ApplicationAnimationBackend {
    public var enhancedUserInterface: Bool { bool("AXEnhancedUserInterface") }

    @discardableResult
    public func setEnhancedUserInterface(_ enabled: Bool) -> Bool {
        set("AXEnhancedUserInterface", enabled ? kCFBooleanTrue : kCFBooleanFalse)
    }

    func value(_ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    func string(_ attribute: String) -> String? {
        value(attribute) as? String
    }

    func bool(_ attribute: String) -> Bool {
        (value(attribute) as? Bool) ?? false
    }

    @discardableResult
    func set(_ attribute: String, _ value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(self, attribute as CFString, value) == .success
    }

    func isSettable(_ attribute: String) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(self, attribute as CFString, &settable) == .success
            && settable.boolValue
    }

    var windows: [AXUIElement] {
        (value(kAXWindowsAttribute) as? [AXUIElement]) ?? []
    }

    var windowID: WindowID? {
        var id: CGWindowID = 0
        return axWindowID(self, &id) == .success && id != 0 ? id : nil
    }

    var pid: pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(self, &pid) == .success ? pid : nil
    }

    public var frame: CGRect? {
        guard let positionValue = value(kAXPositionAttribute),
              let sizeValue = value(kAXSizeAttribute)
        else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        // The attribute values are always AXValues.
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    @discardableResult
    public func setPosition(_ point: CGPoint) -> Bool {
        var point = point
        if let value = AXValueCreate(.cgPoint, &point) {
            return set(kAXPositionAttribute, value)
        }
        return false
    }

    @discardableResult
    public func setSize(_ size: CGSize) -> Bool {
        var size = size
        if let value = AXValueCreate(.cgSize, &size) {
            return set(kAXSizeAttribute, value)
        }
        return false
    }
}

enum Screens {
    /// Monitors in Accessibility coordinates, with y growing downward from
    /// the top of the primary display.
    static func monitors() -> [Monitor] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            return Monitor(
                id: number.uint32Value,
                frame: flip(screen.frame),
                visibleFrame: flip(screen.visibleFrame)
            )
        }
    }

    /// Converts between Cocoa and Accessibility rectangles. The conversion
    /// is its own inverse.
    static func flip(_ rect: CGRect) -> CGRect {
        let height = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }
}
