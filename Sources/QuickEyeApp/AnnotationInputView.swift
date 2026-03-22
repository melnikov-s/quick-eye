import AppKit

final class AnnotationInputView: NSView, NSTextFieldDelegate {
    private let onSubmit: (String) -> Void
    private let onCancel: () -> Void

    let textField = NSTextField()

    private lazy var addButton: NSButton = {
        let button = NSButton(title: "Add", target: self, action: #selector(submit))
        button.bezelStyle = .rounded
        return button
    }()

    private lazy var cancelButton: NSButton = {
        let button = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        button.bezelStyle = .rounded
        return button
    }()

    init(
        initialText: String = "",
        submitButtonTitle: String = "Add",
        onSubmit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor
        layer?.cornerRadius = 16
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor

        textField.placeholderString = "What should the agent change?"
        textField.stringValue = initialText
        textField.delegate = self
        addButton.title = submitButtonTitle
        addSubview(textField)
        addSubview(addButton)
        addSubview(cancelButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()

        textField.frame = CGRect(x: 12, y: 40, width: bounds.width - 24, height: 28)
        addButton.frame = CGRect(x: bounds.width - 82, y: 10, width: 70, height: 24)
        cancelButton.frame = CGRect(x: bounds.width - 160, y: 10, width: 70, height: 24)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            submit()
            return true
        }

        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancel()
            return true
        }

        return false
    }

    @objc
    private func submit() {
        onSubmit(textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @objc
    private func cancel() {
        onCancel()
    }
}
