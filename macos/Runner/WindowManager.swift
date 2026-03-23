//
//  WindowManager.swift
//  Runner
//
//  Handles window discovery and manipulation via Accessibility APIs on macOS.
//  Registered as a method channel handler for "app.afkdev.window_manager".
//

import AppKit
import ApplicationServices
import Cocoa
import CryptoKit
import FlutterMacOS

// Private API to get CGWindowID from AXUIElement
// This function is undocumented but stable across macOS versions
// Used by mature projects like AltTab (https://github.com/lwouis/alt-tab-macos)
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowId: UnsafeMutablePointer<CGWindowID>) -> AXError

class WindowManager: NSObject, FlutterPlugin {
    // MARK: - Multi-Display Support

    /// The CGDirectDisplayID of the display currently being streamed.
    /// Set via the setStreamingDisplayId method channel from Dart.
    /// Defaults to main display if not set.
    private var streamingDisplayID: CGDirectDisplayID = CGMainDisplayID()

    // MARK: - Plugin Registration

    static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "app.afkdev.window_manager",
            binaryMessenger: registrar.messenger
        )
        let instance = WindowManager()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    // MARK: - FlutterPlugin

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "getWindows":
            handleGetWindows(result: result)

        case "focusWindow":
            guard let args = call.arguments as? [String: Any],
                  let windowId = args["id"] as? String
            else {
                result(FlutterError(code: "INVALID_ARGS", message: "focusWindow requires id", details: nil))
                return
            }
            let success = handleFocusWindow(windowId: windowId)
            result(success)

        case "setWindowBounds":
            guard let args = call.arguments as? [String: Any],
                  let windowId = args["id"] as? String,
                  let x = args["x"] as? Double,
                  let y = args["y"] as? Double,
                  let width = args["width"] as? Double,
                  let height = args["height"] as? Double
            else {
                result(FlutterError(code: "INVALID_ARGS", message: "setWindowBounds requires id, x, y, width, height", details: nil))
                return
            }
            let success = handleSetWindowBounds(windowId: windowId, x: x, y: y, width: width, height: height)
            result(success)

        case "getWindowIcon":
            guard let args = call.arguments as? [String: Any],
                  let windowId = args["id"] as? String
            else {
                result(FlutterError(code: "INVALID_ARGS", message: "getWindowIcon requires id", details: nil))
                return
            }
            let iconData = handleGetWindowIcon(windowId: windowId)
            result(iconData)

        case "checkAccessibility":
            let hasAccess = checkAccessibilityPermissions()
            result(hasAccess)

        case "requestAccessibility":
            requestAccessibilityPermissions()
            result(nil)

        case "setStreamingDisplayId":
            guard let args = call.arguments as? [String: Any],
                  let displayId = args["displayId"] as? Int
            else {
                result(FlutterError(code: "INVALID_ARGS", message: "setStreamingDisplayId requires displayId", details: nil))
                return
            }
            streamingDisplayID = CGDirectDisplayID(displayId)
            NSLog("[WindowManager] Streaming display set to: \(streamingDisplayID)")
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Accessibility Permissions

    private func checkAccessibilityPermissions() -> Bool {
        let trusted = AXIsProcessTrusted()
        if !trusted {
            NSLog("[WindowManager] Accessibility permissions not granted")
        }
        return trusted
    }

    private func requestAccessibilityPermissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    // MARK: - Window Discovery

    private func handleGetWindows(result: @escaping FlutterResult) {
        guard checkAccessibilityPermissions() else {
            NSLog("[WindowManager] Accessibility permissions not granted, returning empty list")
            result(["windows": [], "focusedWindowId": nil])
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else {
                result(["windows": [], "focusedWindowId": nil])
                return
            }

            let windows = discoverAllWindows()
            let focusedId = detectFocusedWindowId()

            // Normalize bounds to 0-1 relative to streaming display so the
            // client can map them directly to video coordinates regardless of
            // Retina scaling or display resolution.
            let screenFrame = CGDisplayBounds(self.streamingDisplayID)

            let windowMaps = windows.map { window -> [String: Any] in
                var dict: [String: Any] = [
                    "id": window.id,
                    "title": window.title,
                    "appName": window.appName,
                    "isOnStreamingDisplay": window.isOnStreamingDisplay,
                    "bounds": [
                        "x": screenFrame.width > 0 ? (window.bounds.origin.x - screenFrame.origin.x) / screenFrame.width : 0.0,
                        "y": screenFrame.height > 0 ? (window.bounds.origin.y - screenFrame.origin.y) / screenFrame.height : 0.0,
                        "width": screenFrame.width > 0 ? window.bounds.size.width / screenFrame.width : 0.0,
                        "height": screenFrame.height > 0 ? window.bounds.size.height / screenFrame.height : 0.0,
                    ],
                ]
                if let iconHash = window.iconHash {
                    dict["iconHash"] = iconHash
                }
                return dict
            }

            DispatchQueue.main.async {
                result([
                    "windows": windowMaps,
                    "focusedWindowId": focusedId as Any,
                ])
            }
        }
    }

    private func discoverAllWindows() -> [WindowData] {
        var allWindows: [WindowData] = []
        let runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }

        for app in runningApps {
            guard let appName = app.localizedName,
                  !shouldSkipApp(appName)
            else { continue }

            let appWindows = getWindowsForApp(app)
            allWindows.append(contentsOf: appWindows)
        }

        return allWindows.sorted { first, second in
            if first.appName != second.appName {
                return first.appName < second.appName
            }
            return first.title < second.title
        }
    }

    private func getWindowsForApp(_ app: NSRunningApplication) -> [WindowData] {
        guard let appName = app.localizedName else { return [] }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var windowsRef: CFTypeRef?

        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement]
        else { return [] }

        var windows: [WindowData] = []

        // Get icon hash for this app
        let iconHash = getAppIconHash(for: app)

        for axWindow in axWindows {
            // Filter: Only standard windows
            var roleRef: CFTypeRef?
            var subroleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(axWindow, kAXRoleAttribute as CFString, &roleRef)
            AXUIElementCopyAttributeValue(axWindow, kAXSubroleAttribute as CFString, &subroleRef)

            let role = roleRef as? String
            let subrole = subroleRef as? String

            guard role == kAXWindowRole as String else { continue }

            // Skip dialogs, sheets, floating panels
            if let subrole {
                let skipSubroles = [
                    kAXDialogSubrole as String,
                    kAXSystemDialogSubrole as String,
                    kAXFloatingWindowSubrole as String,
                    kAXSystemFloatingWindowSubrole as String,
                ]
                if skipSubroles.contains(subrole) {
                    continue
                }
            }

            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef)
            let windowTitle = (titleRef as? String) ?? ""

            guard let bounds = getAXWindowBounds(axWindow),
                  bounds.width >= 100, bounds.height >= 100
            else { continue }

            // Get CGWindowID as stable identifier
            guard let cgWindowId = getCGWindowId(from: axWindow) else {
                continue
            }

            let windowId = String(cgWindowId)
            let title = windowTitle.isEmpty ? appName : windowTitle
            let onStreamingDisplay = isWindowOnStreamingDisplay(bounds)

            let window = WindowData(
                id: windowId,
                title: title,
                appName: appName,
                bounds: bounds,
                iconHash: iconHash,
                isOnStreamingDisplay: onStreamingDisplay
            )

            windows.append(window)
        }

        return windows
    }

    private func shouldSkipApp(_ appName: String) -> Bool {
        let skipApps = ["Window Server", "Dock", "SystemUIServer", "Control Center", "NotificationCenter", "Spotlight"]
        return skipApps.contains(appName)
    }

    private func getAXWindowBounds(_ window: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?

        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionValue = positionRef,
              let sizeValue = sizeRef
        else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero

        AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)

        return CGRect(origin: position, size: size)
    }

    private func getCGWindowId(from axWindow: AXUIElement) -> CGWindowID? {
        var windowId: CGWindowID = 0
        let result = _AXUIElementGetWindow(axWindow, &windowId)

        guard result == .success, windowId != 0 else {
            return nil
        }

        return windowId
    }

    // MARK: - Focus Management

    private func detectFocusedWindowId() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedApp: CFTypeRef?

        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedApp) == .success,
              let appElement = focusedApp as! AXUIElement?
        else {
            return nil
        }

        var focusedWindowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindowRef) == .success,
              let windowElement = focusedWindowRef as! AXUIElement?
        else {
            return nil
        }

        guard let cgWindowId = getCGWindowId(from: windowElement) else {
            return nil
        }

        return String(cgWindowId)
    }

    private func handleFocusWindow(windowId: String) -> Bool {
        // Parse window ID (CGWindowID)
        guard let cgWindowId = CGWindowID(windowId) else {
            NSLog("[WindowManager] Invalid window ID format: \(windowId)")
            return false
        }

        // Get PID from CGWindowID
        guard let pid = getPID(for: cgWindowId) else {
            NSLog("[WindowManager] Could not find PID for window ID: \(windowId)")
            return false
        }

        // Resolve target AX window by matching CGWindowID
        var targetWindow: AXUIElement?
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        let windowsResult = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        if windowsResult == .success, let windows = windowsRef as? [AXUIElement] {
            for axWindow in windows {
                if let winId = getCGWindowId(from: axWindow), winId == cgWindowId {
                    targetWindow = axWindow
                    break
                }
            }
        }

        // Try to focus the specific window using Accessibility APIs first.
        // This avoids bringing all windows of the application to the front.
        var focusSuccess = false
        if let targetWindow {
            // Move window to streaming display if it's on a different display
            _ = moveWindowToStreamingDisplayIfNeeded(targetWindow)

            // Method 1: Set as main window
            if AXUIElementSetAttributeValue(targetWindow, kAXMainAttribute as CFString, kCFBooleanTrue) == .success {
                focusSuccess = true
            }

            // Method 2: Raise the window
            if AXUIElementPerformAction(targetWindow, kAXRaiseAction as CFString) == .success {
                focusSuccess = true
            }
        }

        // Get the app to ensure it's active
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == pid }) else {
            NSLog("[WindowManager] App with PID \(pid) not found")
            return false
        }

        // If we successfully focused the specific window via AX, ensure the app is active.
        if focusSuccess {
            if !app.isActive {
                _ = app.activate(options: [])
            }
            return true
        }

        // Fallback: If specific window focus failed (or window not found), use robustActivate.
        // This WILL bring all windows to the front, but it's a necessary fallback.
        return robustActivate(app: app)
    }

    private func robustActivate(app: NSRunningApplication) -> Bool {
        // Normal activate
        _ = app.activate(options: [])
        usleep(150_000)
        if isFrontmost(pid: app.processIdentifier) { return true }

        // If hidden, unhide then activate
        if app.isHidden {
            app.unhide()
            usleep(80000)
            _ = app.activate(options: [])
            usleep(150_000)
            if isFrontmost(pid: app.processIdentifier) { return true }
        }

        // AppleScript fallback
        if let name = app.localizedName, activateUsingAppleScript(appName: name) {
            usleep(180_000)
            if isFrontmost(pid: app.processIdentifier) { return true }
        }

        return isFrontmost(pid: app.processIdentifier)
    }

    private func isFrontmost(pid: pid_t) -> Bool {
        if let front = NSWorkspace.shared.frontmostApplication {
            return front.processIdentifier == pid
        }
        return false
    }

    private func activateUsingAppleScript(appName: String) -> Bool {
        // Sanitize app name to prevent AppleScript injection:
        // escape backslashes first, then double quotes
        let sanitized = appName
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
        tell application "\(sanitized)"
            activate
        end tell
        """
        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: script) {
            _ = scriptObject.executeAndReturnError(&error)
            return error == nil
        }
        return false
    }

    private func getPID(for cgWindowId: CGWindowID) -> pid_t? {
        let options = CGWindowListOption([.optionAll])
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        let windowInfo = windowList.first {
            ($0[kCGWindowNumber as String] as? CGWindowID) == cgWindowId
        }

        return windowInfo?[kCGWindowOwnerPID as String] as? pid_t
    }

    // MARK: - Window Bounds

    private func handleSetWindowBounds(windowId: String, x: Double, y: Double, width: Double, height: Double) -> Bool {
        guard let cgWindowId = CGWindowID(windowId) else {
            NSLog("[WindowManager] Invalid window ID format: \(windowId)")
            return false
        }

        guard let pid = getPID(for: cgWindowId) else {
            NSLog("[WindowManager] Could not find PID for window ID: \(windowId)")
            return false
        }

        // Get screen dimensions of the streaming display
        let screenFrame = CGDisplayBounds(streamingDisplayID)

        // Validate screen dimensions
        guard screenFrame.width > 0, screenFrame.height > 0 else {
            NSLog("[WindowManager] Invalid screen frame dimensions: \(screenFrame)")
            return false
        }

        // Convert normalized coordinates (0-1) to screen pixels on the streaming display
        let targetX = screenFrame.origin.x + (x * screenFrame.width)
        let targetY = screenFrame.origin.y + (y * screenFrame.height)
        let targetWidth = width * screenFrame.width
        let targetHeight = height * screenFrame.height

        // Resolve AX window
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?

        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement]
        else {
            return false
        }

        var targetWindow: AXUIElement?
        for axWindow in windows {
            if let winId = getCGWindowId(from: axWindow), winId == cgWindowId {
                targetWindow = axWindow
                break
            }
        }

        guard let targetWindow else {
            return false
        }

        // Focus window first
        _ = AXUIElementPerformAction(targetWindow, kAXRaiseAction as CFString)

        // Set size (twice for reliability - macOS quirk)
        let targetSize = CGSize(width: targetWidth, height: targetHeight)
        _ = safeSetWindowSize(targetWindow, size: targetSize)
        let sizeSuccess = safeSetWindowSize(targetWindow, size: targetSize)

        // Set position
        let targetPosition = CGPoint(x: targetX, y: targetY)
        let positionSuccess = safeSetWindowPosition(targetWindow, position: targetPosition)

        return sizeSuccess && positionSuccess
    }

    private func safeSetWindowPosition(_ window: AXUIElement, position: CGPoint) -> Bool {
        guard position.x.isFinite, position.y.isFinite,
              position.x >= -10000, position.x <= 10000,
              position.y >= -10000, position.y <= 10000
        else { return false }

        var p = position
        guard let value = AXValueCreate(.cgPoint, &p) else { return false }

        let result = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
        return result == .success
    }

    private func safeSetWindowSize(_ window: AXUIElement, size: CGSize) -> Bool {
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0,
              size.width <= 10000, size.height <= 10000
        else { return false }

        var isSettable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &isSettable) != .success || !isSettable.boolValue {
            return false
        }

        var s = size
        guard let value = AXValueCreate(.cgSize, &s) else { return false }

        let result = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
        return result == .success
    }

    // MARK: - Multi-Display Helpers

    /// Determines which display contains the center point of the given bounds.
    private func getDisplayForWindowBounds(_ bounds: CGRect) -> CGDirectDisplayID? {
        var displayID: CGDirectDisplayID = 0
        var count: UInt32 = 0
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        CGGetDisplaysWithPoint(center, 1, &displayID, &count)
        return count > 0 ? displayID : nil
    }

    /// Checks if a window (by its bounds) is on the streaming display.
    private func isWindowOnStreamingDisplay(_ bounds: CGRect) -> Bool {
        guard let windowDisplay = getDisplayForWindowBounds(bounds) else { return true }
        return windowDisplay == streamingDisplayID
    }

    /// Moves a window to the center of the streaming display if it's on a different display.
    /// Returns true if move was successful or unnecessary (already on streaming display).
    private func moveWindowToStreamingDisplayIfNeeded(_ axWindow: AXUIElement) -> Bool {
        guard let windowBounds = getAXWindowBounds(axWindow) else { return true }

        // Check if already on streaming display
        if isWindowOnStreamingDisplay(windowBounds) {
            return true
        }

        let displayBounds = CGDisplayBounds(streamingDisplayID)

        // Calculate centered position on streaming display
        let centeredX = displayBounds.origin.x + (displayBounds.width - windowBounds.width) / 2
        let centeredY = displayBounds.origin.y + (displayBounds.height - windowBounds.height) / 2

        let moved = safeSetWindowPosition(axWindow, position: CGPoint(x: centeredX, y: centeredY))
        if moved {
            NSLog("[WindowManager] Moved window to streaming display (centered)")
        } else {
            NSLog("[WindowManager] Failed to move window to streaming display")
        }
        return moved
    }

    // MARK: - Icon Management

    private func handleGetWindowIcon(windowId: String) -> [String: Any]? {
        guard let cgWindowId = CGWindowID(windowId) else {
            return nil
        }

        guard let pid = getPID(for: cgWindowId) else {
            return nil
        }

        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == pid }) else {
            return nil
        }

        guard let iconData = getAppIconData(for: app) else {
            return nil
        }

        return [
            "hash": iconData.hash,
            "data": iconData.base64,
        ]
    }

    private func getAppIconHash(for app: NSRunningApplication) -> String? {
        guard let icon = app.icon else { return nil }

        // Resize to 32x32
        let targetSize = NSSize(width: 32, height: 32)
        let resizedIcon = NSImage(size: targetSize)
        resizedIcon.lockFocus()
        icon.draw(in: NSRect(origin: .zero, size: targetSize),
                  from: NSRect(origin: .zero, size: icon.size),
                  operation: .copy,
                  fraction: 1.0)
        resizedIcon.unlockFocus()

        // Convert to PNG
        guard let tiffData = resizedIcon.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:])
        else {
            return nil
        }

        // Compute SHA256 hash
        let hash = SHA256.hash(data: pngData)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    private func getAppIconData(for app: NSRunningApplication) -> IconData? {
        guard let icon = app.icon else { return nil }

        // Resize to 32x32
        let targetSize = NSSize(width: 32, height: 32)
        let resizedIcon = NSImage(size: targetSize)
        resizedIcon.lockFocus()
        icon.draw(in: NSRect(origin: .zero, size: targetSize),
                  from: NSRect(origin: .zero, size: icon.size),
                  operation: .copy,
                  fraction: 1.0)
        resizedIcon.unlockFocus()

        // Convert to PNG
        guard let tiffData = resizedIcon.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:])
        else {
            return nil
        }

        // Compute SHA256 hash
        let hash = SHA256.hash(data: pngData)
        let hashHex = hash.compactMap { String(format: "%02x", $0) }.joined()

        // Convert to base64
        let base64 = pngData.base64EncodedString()

        return IconData(hash: hashHex, base64: base64)
    }
}

// MARK: - Data Structures

private struct WindowData {
    let id: String
    let title: String
    let appName: String
    let bounds: CGRect
    let iconHash: String?
    let isOnStreamingDisplay: Bool
}

private struct IconData {
    let hash: String
    let base64: String
}
