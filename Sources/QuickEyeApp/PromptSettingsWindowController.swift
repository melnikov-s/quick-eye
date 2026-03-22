import AppKit

@MainActor
final class PromptSettingsWindowController: NSWindowController {
    init(store: PromptSettingsStore) {
        let viewController = PromptSettingsViewController(store: store)
        let window = PromptSettingsWindow(
            contentRect: CGRect(x: 0, y: 0, width: 640, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Prompt Settings"
        window.center()
        window.contentViewController = viewController
        super.init(window: window)
        shouldCascadeWindows = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private final class PromptSettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              let characters = event.charactersIgnoringModifiers?.lowercased()
        else {
            return super.performKeyEquivalent(with: event)
        }

        let selector: Selector?
        switch characters {
        case "x":
            selector = #selector(NSText.cut(_:))
        case "c":
            selector = #selector(NSText.copy(_:))
        case "v":
            selector = #selector(NSText.paste(_:))
        case "a":
            selector = #selector(NSText.selectAll(_:))
        case "z":
            selector = #selector(UndoManager.undo)
        default:
            selector = nil
        }

        guard let selector else {
            return super.performKeyEquivalent(with: event)
        }

        if NSApp.sendAction(selector, to: nil, from: self) {
            return true
        }

        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
private final class PromptSettingsViewController: NSViewController {
    private let store: PromptSettingsStore

    private lazy var providerLabel = makeLabel("Provider")
    private lazy var baseURLLabel = makeLabel("Base URL")
    private lazy var modelLabel = makeLabel("Model")
    private lazy var apiKeyLabel = makeLabel("API Key")
    private lazy var promptTemplateLabel = makeLabel("Prompt Template")

    private lazy var providerButton: NSPopUpButton = {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        PromptProvider.allCases.forEach { provider in
            button.addItem(withTitle: provider.displayName)
            button.lastItem?.representedObject = provider
        }
        button.target = self
        button.action = #selector(providerDidChange)
        return button
    }()

    private lazy var baseURLField = NSTextField()
    private lazy var modelField = NSTextField()
    private lazy var apiKeyField = NSSecureTextField()
    private lazy var promptTemplateView: NSTextView = {
        let view = NSTextView(frame: .zero)
        view.isRichText = false
        view.importsGraphics = false
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        return view
    }()
    private lazy var promptTemplateScrollView: NSScrollView = {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = promptTemplateView
        return scrollView
    }()
    private lazy var saveButton: NSButton = {
        let button = NSButton(title: "Save", target: self, action: #selector(saveSettings))
        button.keyEquivalent = "\r"
        return button
    }()
    private lazy var cancelButton: NSButton = {
        let button = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        return button
    }()
    private lazy var restoreBaseURLButton: NSButton = {
        let button = NSButton(title: "Use Default URL", target: self, action: #selector(restoreDefaultBaseURL))
        button.bezelStyle = .rounded
        return button
    }()

    init(store: PromptSettingsStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView(frame: CGRect(x: 0, y: 0, width: 640, height: 520))
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        [
            providerLabel,
            providerButton,
            baseURLLabel,
            baseURLField,
            restoreBaseURLButton,
            modelLabel,
            modelField,
            apiKeyLabel,
            apiKeyField,
            promptTemplateLabel,
            promptTemplateScrollView,
            cancelButton,
            saveButton,
        ].forEach(view.addSubview)

        loadCurrentSettings()
    }

    override func viewDidLayout() {
        super.viewDidLayout()

        let contentBounds = view.bounds.insetBy(dx: 24, dy: 24)
        let labelWidth: CGFloat = 120
        let fieldWidth = contentBounds.width - labelWidth - 16
        let fieldHeight: CGFloat = 28
        var currentY = contentBounds.maxY - 20

        providerLabel.frame = CGRect(x: contentBounds.minX, y: currentY, width: labelWidth, height: 20)
        providerButton.frame = CGRect(x: contentBounds.minX + labelWidth, y: currentY - 4, width: fieldWidth, height: fieldHeight)

        currentY -= 48
        baseURLLabel.frame = CGRect(x: contentBounds.minX, y: currentY, width: labelWidth, height: 20)
        baseURLField.frame = CGRect(x: contentBounds.minX + labelWidth, y: currentY - 4, width: fieldWidth - 120, height: fieldHeight)
        restoreBaseURLButton.frame = CGRect(x: baseURLField.frame.maxX + 8, y: currentY - 4, width: 112, height: fieldHeight)

        currentY -= 48
        modelLabel.frame = CGRect(x: contentBounds.minX, y: currentY, width: labelWidth, height: 20)
        modelField.frame = CGRect(x: contentBounds.minX + labelWidth, y: currentY - 4, width: fieldWidth, height: fieldHeight)

        currentY -= 48
        apiKeyLabel.frame = CGRect(x: contentBounds.minX, y: currentY, width: labelWidth, height: 20)
        apiKeyField.frame = CGRect(x: contentBounds.minX + labelWidth, y: currentY - 4, width: fieldWidth, height: fieldHeight)

        currentY -= 52
        promptTemplateLabel.frame = CGRect(x: contentBounds.minX, y: currentY, width: labelWidth + 100, height: 20)
        promptTemplateScrollView.frame = CGRect(
            x: contentBounds.minX,
            y: contentBounds.minY + 52,
            width: contentBounds.width,
            height: currentY - contentBounds.minY - 64
        )

        cancelButton.frame = CGRect(x: contentBounds.maxX - 170, y: contentBounds.minY, width: 80, height: 32)
        saveButton.frame = CGRect(x: contentBounds.maxX - 84, y: contentBounds.minY, width: 80, height: 32)
    }

    @objc
    private func providerDidChange() {
        applyConfiguration(for: selectedProvider())
    }

    @objc
    private func restoreDefaultBaseURL() {
        baseURLField.stringValue = selectedProvider().defaultBaseURL
    }

    @objc
    private func saveSettings() {
        do {
            try store.save(
                provider: selectedProvider(),
                configuration: PromptProviderConfiguration(
                    baseURL: baseURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                    model: modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                    apiKey: apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                ),
                promptTemplate: promptTemplateView.string.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            view.window?.close()
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Could Not Save Prompt Settings"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc
    private func cancel() {
        view.window?.close()
    }

    private func loadCurrentSettings() {
        let currentProvider = store.currentProvider()
        providerButton.selectItem(at: PromptProvider.allCases.firstIndex(of: currentProvider) ?? 0)
        promptTemplateView.string = store.promptTemplate()
        applyConfiguration(for: currentProvider)
    }

    private func applyConfiguration(for provider: PromptProvider) {
        let configuration = store.configuration(for: provider)
        baseURLField.stringValue = configuration.baseURL
        modelField.stringValue = configuration.model
        apiKeyField.stringValue = configuration.apiKey
    }

    private func selectedProvider() -> PromptProvider {
        (providerButton.selectedItem?.representedObject as? PromptProvider) ?? .gemini
    }

    private func makeLabel(_ string: String) -> NSTextField {
        let label = NSTextField(labelWithString: string)
        label.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }
}
