import AppKit

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let controller: QuickEyeController
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

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

        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        let captureItem = NSMenuItem(
            title: "Capture Screen",
            action: #selector(captureNow),
            keyEquivalent: ""
        )
        captureItem.target = self
        menu.addItem(captureItem)

        let historyItems = controller.captureHistory()
        if !historyItems.isEmpty {
            menu.addItem(NSMenuItem.separator())
            historyItems.forEach { item in
                menu.addItem(makeHistoryMenuItem(for: item))
            }
        }

        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(
            title: "Quit Quick Eye",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func makeHistoryMenuItem(for item: CaptureHistoryItem) -> NSMenuItem {
        let menuItem = NSMenuItem(
            title: "History \(timeFormatter.string(from: item.createdAt))",
            action: #selector(openHistory(_:)),
            keyEquivalent: ""
        )
        menuItem.target = self
        menuItem.representedObject = item.id
        menuItem.image = item.thumbnail
        menuItem.toolTip = "Reopen this annotated capture"
        return menuItem
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

    @objc
    private func openHistory(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        controller.reopenHistoryItem(id: id)
    }
}
