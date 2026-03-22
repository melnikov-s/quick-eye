import AppKit
import CoreGraphics

struct ScreenCapture {
    let image: NSImage
    let screenFrame: CGRect
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
        return ScreenCapture(image: image, screenFrame: screen.frame)
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
}
