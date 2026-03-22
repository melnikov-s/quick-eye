import AppKit

final class AnnotationInputView: NSView, NSTextViewDelegate {
    private enum Layout {
        static let horizontalPadding: CGFloat = 12
        static let topPadding: CGFloat = 12
        static let bottomPadding: CGFloat = 12
        static let minHeight: CGFloat = 76
        static let maxHeight: CGFloat = 230
    }

    private let onSubmit: (String) -> Void
    private let onCancel: () -> Void

    var onPreferredHeightChange: ((CGFloat) -> Void)?

    private lazy var textView: NSTextView = {
        let view = NSTextView(frame: .zero)
        view.delegate = self
        view.drawsBackground = false
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.font = NSFont.systemFont(ofSize: 13)
        view.textContainerInset = CGSize(width: 2, height: 6)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.minSize = CGSize(width: 0, height: 0)
        view.maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.heightTracksTextView = false
        return view
    }()

    private lazy var scrollView: NSScrollView = {
        let view = NSScrollView()
        view.borderType = .bezelBorder
        view.hasVerticalScroller = true
        view.drawsBackground = false
        view.documentView = textView
        return view
    }()

    private lazy var placeholderLabel: NSTextField = {
        let label = NSTextField(labelWithString: "What should the agent change?")
        label.textColor = .placeholderTextColor
        label.font = NSFont.systemFont(ofSize: 13)
        return label
    }()

    private var lastReportedHeight: CGFloat = Layout.minHeight

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

        textView.string = initialText

        addSubview(scrollView)
        addSubview(placeholderLabel)
        updatePlaceholderVisibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()

        scrollView.frame = CGRect(
            x: Layout.horizontalPadding,
            y: Layout.bottomPadding,
            width: bounds.width - (Layout.horizontalPadding * 2),
            height: max(40, bounds.height - Layout.topPadding - Layout.bottomPadding)
        )

        placeholderLabel.frame = CGRect(
            x: scrollView.frame.minX + 8,
            y: scrollView.frame.maxY - 28,
            width: scrollView.frame.width - 16,
            height: 18
        )

        updatePreferredHeightIfNeeded()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focus()
    }

    func focus() {
        window?.makeFirstResponder(textView)
    }

    func accept() {
        submit()
    }

    func textDidChange(_ notification: Notification) {
        updatePlaceholderVisibility()
        updatePreferredHeightIfNeeded()
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                return false
            }

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
        onSubmit(textView.string.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @objc
    private func cancel() {
        onCancel()
    }

    private func updatePlaceholderVisibility() {
        placeholderLabel.isHidden = !textView.string.isEmpty
    }

    private func updatePreferredHeightIfNeeded() {
        let targetHeight = preferredHeight(forWidth: max(bounds.width, 280))
        guard abs(targetHeight - lastReportedHeight) > 1 else { return }
        lastReportedHeight = targetHeight
        onPreferredHeightChange?(targetHeight)
    }

    private func preferredHeight(forWidth width: CGFloat) -> CGFloat {
        let textAreaWidth = width - (Layout.horizontalPadding * 2) - 4
        guard textAreaWidth > 0 else { return Layout.minHeight }

        let measuredTextHeight = measuredHeight(for: textAreaWidth)
        let desiredHeight = measuredTextHeight
            + Layout.topPadding
            + Layout.bottomPadding

        return min(max(Layout.minHeight, desiredHeight), Layout.maxHeight)
    }

    private func measuredHeight(for width: CGFloat) -> CGFloat {
        guard let textContainer = textView.textContainer,
              let layoutManager = textView.layoutManager else {
            return 44
        }

        textContainer.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        return max(44, ceil(usedRect.height + (textView.textContainerInset.height * 2)))
    }
}
