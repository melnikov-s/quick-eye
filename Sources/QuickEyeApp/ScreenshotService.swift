import AppKit
import CoreGraphics

struct ScreenCapture {
    let image: NSImage
    let screenFrame: CGRect
    let defaultExportRect: CGRect
}

@MainActor
struct ScreenshotService {
    enum CaptureError: LocalizedError {
        case permissionDenied
        case noScreenAvailable
        case imageUnavailable

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Screen Recording permission was denied."
            case .noScreenAvailable:
                return "No screen is available for capture."
            case .imageUnavailable:
                return "macOS could not create a screenshot for the current display."
            }
        }
    }

    func captureCurrentScreen() throws -> ScreenCapture {
        guard requestScreenCapturePermission() else {
            throw CaptureError.permissionDenied
        }

        guard let screen = screenForCurrentPointer() else {
            throw CaptureError.noScreenAvailable
        }

        guard
            let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
            let cgImage = CGDisplayCreateImage(displayID)
        else {
            throw CaptureError.imageUnavailable
        }

        let image = NSImage(cgImage: cgImage, size: screen.frame.size)
        let defaultExportRect = preferredExportRect(for: screen)

        return ScreenCapture(
            image: image,
            screenFrame: screen.frame,
            defaultExportRect: defaultExportRect
        )
    }

    private func requestScreenCapturePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }

        return CGRequestScreenCaptureAccess()
    }

    private func screenForCurrentPointer() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main
    }

    private func preferredExportRect(for screen: NSScreen) -> CGRect {
        let visibleRect = CGRect(
            x: max(0, screen.visibleFrame.minX - screen.frame.minX),
            y: max(0, screen.visibleFrame.minY - screen.frame.minY),
            width: min(screen.frame.width, screen.visibleFrame.width),
            height: min(screen.frame.height, screen.visibleFrame.height)
        )

        guard let frontmostWindowRect = frontmostWindowRect(on: screen) else {
            return visibleRect
        }

        let clippedWindowRect = frontmostWindowRect.intersection(visibleRect)
        guard !clippedWindowRect.isNull, clippedWindowRect.width > 0, clippedWindowRect.height > 0 else {
            return visibleRect
        }

        return clippedWindowRect
    }

    private func frontmostWindowRect(on screen: NSScreen) -> CGRect? {
        guard let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let windowInfoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else {
            return nil
        }

        let minimumWindowSize: CGFloat = 80

        for windowInfo in windowInfoList {
            guard let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == frontmostPID,
                  let layer = windowInfo[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let alpha = windowInfo[kCGWindowAlpha as String] as? Double,
                  alpha > 0.01,
                  let boundsDictionary = windowInfo[kCGWindowBounds as String] as? NSDictionary,
                  let globalBounds = CGRect(dictionaryRepresentation: boundsDictionary)
            else {
                continue
            }

            guard globalBounds.width >= minimumWindowSize,
                  globalBounds.height >= minimumWindowSize else {
                continue
            }

            let clippedToScreen = globalBounds.intersection(screen.frame)
            guard !clippedToScreen.isNull,
                  clippedToScreen.width > 0,
                  clippedToScreen.height > 0 else {
                continue
            }

            return CGRect(
                x: clippedToScreen.minX - screen.frame.minX,
                y: screen.frame.maxY - clippedToScreen.maxY,
                width: clippedToScreen.width,
                height: clippedToScreen.height
            )
        }

        return nil
    }
}
