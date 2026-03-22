import AppKit

final class CaptureHUDView: NSView {
    private let onDone: () -> Void
    private let onCancel: () -> Void
    private let onClear: () -> Void

    private lazy var titleLabel: NSTextField = {
        let label = NSTextField(labelWithString: "Drag to place an arrow, then type a note.")
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        return label
    }()

    private lazy var doneButton: NSButton = {
        let button = NSButton(title: "Done", target: self, action: #selector(done))
        button.bezelStyle = .rounded
        return button
    }()
    private lazy var cancelButton: NSButton = {
        let button = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        button.bezelStyle = .rounded
        return button
    }()
    private lazy var clearButton: NSButton = {
        let button = NSButton(title: "Clear", target: self, action: #selector(clear))
        button.bezelStyle = .rounded
        return button
    }()

    init(
        onDone: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onClear: @escaping () -> Void
    ) {
        self.onDone = onDone
        self.onCancel = onCancel
        self.onClear = onClear
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.94).cgColor
        layer?.cornerRadius = 22
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor

        [
            titleLabel,
            clearButton,
            cancelButton,
            doneButton,
        ].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var fittingSize: NSSize {
        NSSize(width: 420, height: 70)
    }

    override func layout() {
        super.layout()
        titleLabel.frame = CGRect(x: 16, y: 40, width: 270, height: 18)
        clearButton.frame = CGRect(x: bounds.width - 220, y: 12, width: 60, height: 24)
        cancelButton.frame = CGRect(x: bounds.width - 150, y: 12, width: 60, height: 24)
        doneButton.frame = CGRect(x: bounds.width - 80, y: 12, width: 60, height: 24)
    }

    @objc
    private func done() {
        onDone()
    }

    @objc
    private func cancel() {
        onCancel()
    }

    @objc
    private func clear() {
        onClear()
    }
}
