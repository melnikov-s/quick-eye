import AppKit

@MainActor
final class StatusItemController: NSObject {
    private let controller: QuickEyeController
    private let statusItem: NSStatusItem

    init(controller: QuickEyeController) {
        self.controller = controller
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureStatusItem()
    }

    private func configureStatusItem() {
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "eye.circle",
                accessibilityDescription: "Quick Eye"
            )
        }

        let menu = NSMenu()
        menu.addItem(
            withTitle: "Capture Screen",
            action: #selector(captureNow),
            keyEquivalent: ""
        )
        menu.addItem(NSMenuItem.separator())
        menu.addItem(
            withTitle: "Quit Quick Eye",
            action: #selector(quit),
            keyEquivalent: "q"
        )

        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
    }

    @objc
    private func captureNow() {
        Task { @MainActor [weak self] in
            await self?.controller.beginCapture()
        }
    }

    @objc
    private func quit() {
        controller.quit()
    }
}
