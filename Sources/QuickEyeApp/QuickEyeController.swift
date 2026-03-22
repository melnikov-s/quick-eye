import AppKit

@MainActor
final class QuickEyeController {
    private let screenshotService = ScreenshotService()
    private let clipboardService = ClipboardService()
    private let hotkeyManager = HotkeyManager()
    private let historyLimit = 10

    private var annotationWindowController: AnnotationWindowController?
    private var isCapturing = false
    private var historyItems: [CaptureHistoryItem] = []

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

    func captureHistory() -> [CaptureHistoryItem] {
        historyItems
    }

    func reopenHistoryItem(id: UUID) {
        guard let item = historyItems.first(where: { $0.id == id }) else { return }
        presentAnnotationWindow(
            with: item.capture,
            initialState: item.state,
            historyItemID: item.id
        )
    }

    private func presentAnnotationWindow(
        with capture: ScreenCapture,
        initialState: AnnotationHistoryState? = nil,
        historyItemID: UUID? = nil
    ) {
        annotationWindowController?.close()

        let controller = AnnotationWindowController(
            capture: capture,
            initialState: initialState,
            historyItemID: historyItemID,
            onComplete: { [weak self] image, historyItem in
                if let historyItem {
                    self?.storeHistoryItem(historyItem)
                } else if let historyItemID {
                    self?.removeHistoryItem(id: historyItemID)
                }
                self?.clipboardService.copy(image: image)
                self?.annotationWindowController?.close()
                self?.annotationWindowController = nil
            },
            onCancel: { [weak self] historyItem in
                if let historyItem {
                    self?.storeHistoryItem(historyItem)
                } else if let historyItemID {
                    self?.removeHistoryItem(id: historyItemID)
                }
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

    private func storeHistoryItem(_ historyItem: CaptureHistoryItem) {
        historyItems.removeAll { $0.id == historyItem.id }
        historyItems.insert(historyItem, at: 0)
        if historyItems.count > historyLimit {
            historyItems = Array(historyItems.prefix(historyLimit))
        }
    }

    private func removeHistoryItem(id: UUID) {
        historyItems.removeAll { $0.id == id }
    }
}
