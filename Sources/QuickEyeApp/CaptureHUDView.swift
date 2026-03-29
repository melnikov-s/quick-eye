import AppKit

final class CaptureHUDView: NSView {
    private enum Layout {
        static let width: CGFloat = 700
        static let height: CGFloat = 126
        static let buttonSize = CGSize(width: 34, height: 34)
        static let edgeInset: CGFloat = 16
    }

    private final class DragSurfaceView: NSView {
        weak var hudView: CaptureHUDView?

        private var dragStartPoint: CGPoint?
        private var dragStartFrame: CGRect?

        override func mouseDown(with event: NSEvent) {
            guard let hudView, let superview = hudView.superview else {
                super.mouseDown(with: event)
                return
            }

            dragStartPoint = superview.convert(event.locationInWindow, from: nil)
            dragStartFrame = hudView.frame
        }

        override func mouseDragged(with event: NSEvent) {
            guard let hudView,
                  let superview = hudView.superview,
                  let dragStartPoint,
                  let dragStartFrame else {
                super.mouseDragged(with: event)
                return
            }

            let currentPoint = superview.convert(event.locationInWindow, from: nil)
            let delta = currentPoint - dragStartPoint
            let unclampedOrigin = CGPoint(
                x: dragStartFrame.minX + delta.width,
                y: dragStartFrame.minY + delta.height
            )
            hudView.frame.origin = hudView.clampedOrigin(for: unclampedOrigin, in: superview.bounds)
        }

        override func mouseUp(with event: NSEvent) {
            dragStartPoint = nil
            dragStartFrame = nil
            super.mouseUp(with: event)
        }
    }

    private let onDone: () -> Void
    private let onDoneAutoCrop: () -> Void
    private let onDoneManualCrop: () -> Void
    private let onDoneConvertToText: () -> Void
    private let onDiscard: () -> Void
    private let onUndo: () -> Void
    private let onRedo: () -> Void
    private let onToolChange: (ToolMode) -> Void
    private let onStrokeColorChange: (NSColor) -> Void
    private let onAutoLabelChange: (Bool) -> Void

    private let strokeColorOptions: [ColorOption] = [
        ColorOption(name: "Red", color: .systemRed),
        ColorOption(name: "Orange", color: .systemOrange),
        ColorOption(name: "Yellow", color: .systemYellow),
        ColorOption(name: "Green", color: .systemGreen),
        ColorOption(name: "Blue", color: .systemBlue),
        ColorOption(name: "Pink", color: .systemPink),
        ColorOption(name: "White", color: .white),
    ]

    private lazy var dragSurfaceView: DragSurfaceView = {
        let view = DragSurfaceView(frame: .zero)
        view.hudView = self
        view.autoresizingMask = [.width, .height]
        return view
    }()

    private lazy var titleLabel: NSTextField = {
        let label = NSTextField(labelWithString: ToolMode.arrow.description)
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        return label
    }()

    private lazy var arrowToolButton = makeToolButton(
        symbolName: "arrow.up.right",
        accessibilityLabel: "Arrow tool: drag to point at something, then add a note",
        action: #selector(selectArrowTool)
    )
    private lazy var rectangleToolButton = makeToolButton(
        symbolName: "rectangle",
        accessibilityLabel: "Box tool: drag a rectangle around an area, then add a note",
        action: #selector(selectRectangleTool)
    )
    private lazy var ellipseToolButton = makeToolButton(
        symbolName: "circle",
        accessibilityLabel: "Circle tool: drag an ellipse around an area, then add a note",
        action: #selector(selectEllipseTool)
    )
    private lazy var freeformToolButton = makeToolButton(
        symbolName: "scribble",
        accessibilityLabel: "Freeform tool: draw around an area, then add a note",
        action: #selector(selectFreeformTool)
    )
    private lazy var labelToolButton = makeToolButton(
        symbolName: "text.bubble",
        accessibilityLabel: "Label tool: click anywhere to place a standalone label",
        action: #selector(selectLabelTool)
    )

    private lazy var strokeColorButton = makeMenuButton(
        symbolName: "paintpalette",
        accessibilityLabel: "Stroke color: choose the color for arrows and shapes"
    )

    private lazy var autoLabelToggle: NSButton = {
        let button = NSButton(checkboxWithTitle: "Auto label", target: self, action: #selector(toggleAutoLabel))
        button.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        button.state = .on
        button.toolTip = "When enabled, drawing a shape immediately opens a label editor"
        return button
    }()

    private lazy var undoButton = makeToolButton(
        symbolName: "arrow.uturn.backward",
        accessibilityLabel: "Undo the last annotation change",
        action: #selector(undo)
    )
    private lazy var redoButton = makeToolButton(
        symbolName: "arrow.uturn.forward",
        accessibilityLabel: "Redo the last undone change",
        action: #selector(redo)
    )
    private lazy var clearButton = makeToolButton(
        symbolName: "trash",
        accessibilityLabel: "Discard this capture and remove it from history if it was saved",
        action: #selector(discardCapture)
    )
    private lazy var doneButton = makeToolButton(
        symbolName: "checkmark",
        accessibilityLabel: "Copy the full annotated screenshot (Enter)",
        action: #selector(done)
    )
    private lazy var doneAutoCropButton = makeToolButton(
        symbolName: "checkmark.rectangle",
        accessibilityLabel: "Auto-crop around annotations, then copy (Shift+Enter)",
        action: #selector(doneAutoCrop)
    )
    private lazy var doneManualCropButton = makeToolButton(
        symbolName: "crop",
        accessibilityLabel: "Manually crop an area, then copy (Shift+Command+Enter)",
        action: #selector(doneManualCrop)
    )
    private lazy var doneConvertToTextButton = makeToolButton(
        symbolName: "text.quote",
        accessibilityLabel: "Convert the full annotated capture into text and copy it (Command+Enter)",
        action: #selector(doneConvertToText)
    )
    private lazy var progressIndicator: NSProgressIndicator = {
        let indicator = NSProgressIndicator()
        indicator.style = .spinning
        indicator.controlSize = .small
        indicator.isDisplayedWhenStopped = false
        return indicator
    }()

    private var selectedTool: ToolMode = .arrow
    private var statusTextOverride: String?
    private var isBusy = false
    private var canUndo = false
    private var canRedo = false

    init(
        onDone: @escaping () -> Void,
        onDoneAutoCrop: @escaping () -> Void,
        onDoneManualCrop: @escaping () -> Void,
        onDoneConvertToText: @escaping () -> Void,
        onDiscard: @escaping () -> Void,
        onUndo: @escaping () -> Void,
        onRedo: @escaping () -> Void,
        onToolChange: @escaping (ToolMode) -> Void,
        onStrokeColorChange: @escaping (NSColor) -> Void,
        onAutoLabelChange: @escaping (Bool) -> Void
    ) {
        self.onDone = onDone
        self.onDoneAutoCrop = onDoneAutoCrop
        self.onDoneManualCrop = onDoneManualCrop
        self.onDoneConvertToText = onDoneConvertToText
        self.onDiscard = onDiscard
        self.onUndo = onUndo
        self.onRedo = onRedo
        self.onToolChange = onToolChange
        self.onStrokeColorChange = onStrokeColorChange
        self.onAutoLabelChange = onAutoLabelChange
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.94).cgColor
        layer?.cornerRadius = 22
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor

        configureMenus()

        addSubview(dragSurfaceView)

        [
            titleLabel,
            arrowToolButton,
            rectangleToolButton,
            ellipseToolButton,
            freeformToolButton,
            labelToolButton,
            strokeColorButton,
            autoLabelToggle,
            undoButton,
            redoButton,
            clearButton,
            doneManualCropButton,
            doneAutoCropButton,
            doneConvertToTextButton,
            doneButton,
            progressIndicator,
        ].forEach(addSubview)

        setTool(.arrow)
        setAutoLabelEnabled(true)
        selectColorOption(strokeColorOptions[0], tag: 0, on: strokeColorButton)
        onStrokeColorChange(strokeColorOptions[0].color)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var fittingSize: NSSize {
        NSSize(width: Layout.width, height: Layout.height)
    }

    override func layout() {
        super.layout()

        dragSurfaceView.frame = bounds

        titleLabel.frame = CGRect(
            x: Layout.edgeInset,
            y: bounds.height - 34,
            width: bounds.width - 56,
            height: 18
        )
        progressIndicator.frame = CGRect(x: bounds.width - 32, y: bounds.height - 36, width: 16, height: 16)

        let toolY = bounds.height - 82
        arrowToolButton.frame = CGRect(x: 16, y: toolY, width: Layout.buttonSize.width, height: Layout.buttonSize.height)
        rectangleToolButton.frame = CGRect(x: 56, y: toolY, width: Layout.buttonSize.width, height: Layout.buttonSize.height)
        ellipseToolButton.frame = CGRect(x: 96, y: toolY, width: Layout.buttonSize.width, height: Layout.buttonSize.height)
        freeformToolButton.frame = CGRect(x: 136, y: toolY, width: Layout.buttonSize.width, height: Layout.buttonSize.height)
        labelToolButton.frame = CGRect(x: 176, y: toolY, width: Layout.buttonSize.width, height: Layout.buttonSize.height)
        strokeColorButton.frame = CGRect(x: 224, y: toolY, width: 48, height: Layout.buttonSize.height)
        autoLabelToggle.frame = CGRect(x: 288, y: toolY + 7, width: 120, height: 20)

        let actionY: CGFloat = 16
        undoButton.frame = CGRect(x: bounds.width - 330, y: actionY, width: Layout.buttonSize.width, height: Layout.buttonSize.height)
        redoButton.frame = CGRect(x: bounds.width - 290, y: actionY, width: Layout.buttonSize.width, height: Layout.buttonSize.height)
        clearButton.frame = CGRect(x: bounds.width - 210, y: actionY, width: Layout.buttonSize.width, height: Layout.buttonSize.height)
        doneManualCropButton.frame = CGRect(x: bounds.width - 170, y: actionY, width: Layout.buttonSize.width, height: Layout.buttonSize.height)
        doneAutoCropButton.frame = CGRect(x: bounds.width - 130, y: actionY, width: Layout.buttonSize.width, height: Layout.buttonSize.height)
        doneConvertToTextButton.frame = CGRect(x: bounds.width - 90, y: actionY, width: Layout.buttonSize.width, height: Layout.buttonSize.height)
        doneButton.frame = CGRect(x: bounds.width - 50, y: actionY, width: Layout.buttonSize.width, height: Layout.buttonSize.height)
    }

    func setTool(_ tool: ToolMode) {
        selectedTool = tool
        refreshTitle()

        let buttonsByTool: [(ToolMode, NSButton)] = [
            (.arrow, arrowToolButton),
            (.rectangle, rectangleToolButton),
            (.ellipse, ellipseToolButton),
            (.freeform, freeformToolButton),
            (.label, labelToolButton),
        ]

        for (mode, button) in buttonsByTool {
            button.isBordered = mode == tool
            button.contentTintColor = mode == tool ? .controlAccentColor : .secondaryLabelColor
        }
    }

    func setAutoLabelEnabled(_ isEnabled: Bool) {
        autoLabelToggle.state = isEnabled ? .on : .off
    }

    func setUndoRedoState(canUndo: Bool, canRedo: Bool) {
        self.canUndo = canUndo
        self.canRedo = canRedo
        undoButton.isEnabled = canUndo
        redoButton.isEnabled = canRedo
        undoButton.alphaValue = canUndo ? 1 : 0.45
        redoButton.alphaValue = canRedo ? 1 : 0.45
        updateBusyState()
    }

    func setStatusMessage(_ message: String?) {
        statusTextOverride = message
        refreshTitle()
    }

    func setBusyState(isBusy: Bool, message: String?) {
        self.isBusy = isBusy
        statusTextOverride = message
        if isBusy {
            progressIndicator.startAnimation(nil)
        } else {
            progressIndicator.stopAnimation(nil)
        }
        updateBusyState()
        refreshTitle()
    }

    @objc
    private func done() {
        onDone()
    }

    @objc
    private func doneAutoCrop() {
        onDoneAutoCrop()
    }

    @objc
    private func doneManualCrop() {
        onDoneManualCrop()
    }

    @objc
    private func doneConvertToText() {
        onDoneConvertToText()
    }

    @objc
    private func discardCapture() {
        onDiscard()
    }

    @objc
    private func undo() {
        onUndo()
    }

    @objc
    private func redo() {
        onRedo()
    }

    @objc
    private func selectArrowTool() {
        setTool(.arrow)
        onToolChange(.arrow)
    }

    @objc
    private func selectRectangleTool() {
        setTool(.rectangle)
        onToolChange(.rectangle)
    }

    @objc
    private func selectEllipseTool() {
        setTool(.ellipse)
        onToolChange(.ellipse)
    }

    @objc
    private func selectFreeformTool() {
        setTool(.freeform)
        onToolChange(.freeform)
    }

    @objc
    private func selectLabelTool() {
        setTool(.label)
        onToolChange(.label)
    }

    @objc
    private func toggleAutoLabel() {
        onAutoLabelChange(autoLabelToggle.state == .on)
    }

    private func configureMenus() {
        strokeColorButton.menu = makeColorMenu(options: strokeColorOptions, selector: #selector(selectStrokeColor(_:)))
        strokeColorButton.selectItem(at: 0)
    }

    private func makeColorMenu(options: [ColorOption], selector: Selector) -> NSMenu {
        let menu = NSMenu()
        for (index, option) in options.enumerated() {
            let item = NSMenuItem(
                title: " ",
                action: selector,
                keyEquivalent: ""
            )
            item.target = self
            item.tag = index
            item.image = option.color.quickEyeMenuSwatchImage
            item.toolTip = option.name
            menu.addItem(item)
        }
        return menu
    }

    @objc
    private func selectStrokeColor(_ sender: NSMenuItem) {
        let option = strokeColorOptions[sender.tag]
        selectColorOption(option, tag: sender.tag, on: strokeColorButton)
        onStrokeColorChange(option.color)
    }

    private func selectColorOption(_ option: ColorOption, tag: Int, on button: NSPopUpButton) {
        button.selectItem(at: tag)
        button.toolTip = "\(option.name) stroke color"
    }

    private func refreshTitle() {
        titleLabel.stringValue = statusTextOverride ?? selectedTool.description
    }

    private func updateBusyState() {
        let toolButtons: [NSControl] = [
            arrowToolButton,
            rectangleToolButton,
            ellipseToolButton,
            freeformToolButton,
            labelToolButton,
            strokeColorButton,
            autoLabelToggle,
            undoButton,
            redoButton,
            clearButton,
            doneManualCropButton,
            doneAutoCropButton,
            doneConvertToTextButton,
            doneButton,
        ]

        if isBusy {
            toolButtons.forEach {
                $0.isEnabled = false
                $0.alphaValue = 0.5
            }
            progressIndicator.alphaValue = 1
            return
        }

        arrowToolButton.isEnabled = true
        rectangleToolButton.isEnabled = true
        ellipseToolButton.isEnabled = true
        freeformToolButton.isEnabled = true
        labelToolButton.isEnabled = true
        strokeColorButton.isEnabled = true
        autoLabelToggle.isEnabled = true
        undoButton.isEnabled = canUndo
        redoButton.isEnabled = canRedo
        clearButton.isEnabled = true
        doneManualCropButton.isEnabled = true
        doneAutoCropButton.isEnabled = true
        doneConvertToTextButton.isEnabled = true
        doneButton.isEnabled = true

        [arrowToolButton, rectangleToolButton, ellipseToolButton, freeformToolButton, labelToolButton].forEach { $0.alphaValue = 1 }
        strokeColorButton.alphaValue = 1
        autoLabelToggle.alphaValue = 1
        clearButton.alphaValue = 1
        doneManualCropButton.alphaValue = 1
        doneAutoCropButton.alphaValue = 1
        doneConvertToTextButton.alphaValue = 1
        doneButton.alphaValue = 1
        undoButton.alphaValue = canUndo ? 1 : 0.45
        redoButton.alphaValue = canRedo ? 1 : 0.45
        progressIndicator.alphaValue = 0
    }

    private func makeToolButton(symbolName: String, accessibilityLabel: String, action: Selector) -> NSButton {
        let button = NSButton(
            image: NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityLabel)!,
            target: self,
            action: action
        )
        button.isBordered = false
        button.bezelStyle = .texturedRounded
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = .secondaryLabelColor
        button.setButtonType(.momentaryPushIn)
        button.toolTip = accessibilityLabel
        return button
    }

    private func makeMenuButton(symbolName: String, accessibilityLabel: String) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.bezelStyle = .rounded
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        button.title = ""
        button.toolTip = accessibilityLabel
        return button
    }

    private func clampedOrigin(for origin: CGPoint, in bounds: CGRect) -> CGPoint {
        let inset: CGFloat = 12
        return CGPoint(
            x: min(max(origin.x, bounds.minX + inset), bounds.maxX - frame.width - inset),
            y: min(max(origin.y, bounds.minY + inset), bounds.maxY - frame.height - inset)
        )
    }

}
