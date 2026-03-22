import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let appController = QuickEyeController()
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItemController = StatusItemController(controller: appController)
        appController.start()
    }
}
