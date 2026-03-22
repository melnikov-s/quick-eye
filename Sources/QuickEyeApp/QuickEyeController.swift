import AppKit

@MainActor
final class QuickEyeController {
    private let screenshotService = ScreenshotService()
    private let clipboardService = ClipboardService()
    private let hotkeyManager = HotkeyManager()

    private var annotationWindowController: AnnotationWindowController?
    private var isCapturing = false

    func start() {
        hotkeyManager.registerDefaultHotKey { [weak self] in
            Task { @MainActor [weak self] in
                await self?.beginCapture()
            }
        }
    }

    func beginCapture() async {
        guard !isCapturing else { return }
        isCapturing = true
        defer { isCapturing = false }

        do {
            let capture = try screenshotService.captureCurrentScreen()
            presentAnnotationWindow(with: capture)
        } catch ScreenshotService.CaptureError.permissionDenied {
            showAlert(
                title: "Screen Recording Access Required",
                message: "Quick Eye needs Screen Recording permission in System Settings so it can grab your screen and prepare an annotated image for paste."
            )
        } catch ScreenshotService.CaptureError.noScreenAvailable {
            showAlert(
                title: "No Active Screen",
                message: "Quick Eye could not determine which display to capture."
            )
        } catch {
            showAlert(
                title: "Capture Failed",
                message: error.localizedDescription
            )
        }
    }

    func quit() {
        NSApp.terminate(nil)
    }

    private func presentAnnotationWindow(with capture: ScreenCapture) {
        annotationWindowController?.close()

        let controller = AnnotationWindowController(
            capture: capture,
            onComplete: { [weak self] image in
                self?.clipboardService.copy(image: image)
                self?.annotationWindowController?.close()
                self?.annotationWindowController = nil
            },
            onCancel: { [weak self] in
                self?.annotationWindowController?.close()
                self?.annotationWindowController = nil
            }
        )

        annotationWindowController = controller
        controller.showWindow(nil)
    }

    private func showAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
