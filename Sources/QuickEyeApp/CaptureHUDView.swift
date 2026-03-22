import AppKit

final class CaptureHUDView: NSView {
    private let onDone: () -> Void
    private let onCancel: () -> Void
    private let onClear: () -> Void
    private let onUndo: () -> Void
    private let onRedo: () -> Void
    private let onToolChange: (ToolMode) -> Void
    private let onStrokeColorChange: (NSColor) -> Void

    private let strokeColorOptions: [ColorOption] = [
        ColorOption(name: "Red", color: .systemRed),
        ColorOption(name: "Orange", color: .systemOrange),
        ColorOption(name: "Yellow", color: .systemYellow),
        ColorOption(name: "Green", color: .systemGreen),
        ColorOption(name: "Blue", color: .systemBlue),
        ColorOption(name: "Pink", color: .systemPink),
        ColorOption(name: "White", color: .white),
    ]

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
    private lazy var cropToolButton = makeToolButton(
        symbolName: "crop",
        accessibilityLabel: "Crop tool: manually choose the exported area",
        action: #selector(selectCropTool)
    )

    private lazy var strokeColorButton = makeMenuButton(
        symbolName: "paintpalette",
        accessibilityLabel: "Stroke color: choose the color for arrows and shapes"
    )

    private lazy var undoButton = makeToolButton(
        symbolName: "arrow.uturn.backward",
        accessibilityLabel: "Undo the last annotation or crop change",
        action: #selector(undo)
    )
    private lazy var redoButton = makeToolButton(
        symbolName: "arrow.uturn.forward",
        accessibilityLabel: "Redo the last undone change",
        action: #selector(redo)
    )
    private lazy var clearButton = makeToolButton(
        symbolName: "trash",
        accessibilityLabel: "Clear all annotations and any manual crop",
        action: #selector(clear)
    )
    private lazy var cancelButton = makeToolButton(
        symbolName: "xmark",
        accessibilityLabel: "Cancel this capture without copying anything (Esc)",
        action: #selector(cancel)
    )
    private lazy var doneButton = makeToolButton(
        symbolName: "checkmark",
        accessibilityLabel: "Copy the full annotated screenshot",
        action: #selector(done)
    )

    private var selectedTool: ToolMode = .arrow

    init(
        onDone: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onClear: @escaping () -> Void,
        onUndo: @escaping () -> Void,
        onRedo: @escaping () -> Void,
        onToolChange: @escaping (ToolMode) -> Void,
        onStrokeColorChange: @escaping (NSColor) -> Void
    ) {
        self.onDone = onDone
        self.onCancel = onCancel
        self.onClear = onClear
        self.onUndo = onUndo
        self.onRedo = onRedo
        self.onToolChange = onToolChange
        self.onStrokeColorChange = onStrokeColorChange
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.94).cgColor
        layer?.cornerRadius = 22
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor

        configureMenus()

        [
            titleLabel,
            arrowToolButton,
            rectangleToolButton,
            ellipseToolButton,
            freeformToolButton,
            cropToolButton,
            strokeColorButton,
            undoButton,
            redoButton,
            clearButton,
            cancelButton,
            doneButton,
        ].forEach(addSubview)

        setTool(.arrow)
        selectColorOption(strokeColorOptions[0], on: strokeColorButton)
        onStrokeColorChange(strokeColorOptions[0].color)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var fittingSize: NSSize {
        NSSize(width: 560, height: 126)
    }

    override func layout() {
        super.layout()

        titleLabel.frame = CGRect(x: 18, y: bounds.height - 34, width: bounds.width - 36, height: 18)

        let toolButtonSize = CGSize(width: 34, height: 34)
        let toolY = bounds.height - 82
        arrowToolButton.frame = CGRect(x: 18, y: toolY, width: toolButtonSize.width, height: toolButtonSize.height)
        rectangleToolButton.frame = CGRect(x: 58, y: toolY, width: toolButtonSize.width, height: toolButtonSize.height)
        ellipseToolButton.frame = CGRect(x: 98, y: toolY, width: toolButtonSize.width, height: toolButtonSize.height)
        freeformToolButton.frame = CGRect(x: 138, y: toolY, width: toolButtonSize.width, height: toolButtonSize.height)
        cropToolButton.frame = CGRect(x: 178, y: toolY, width: toolButtonSize.width, height: toolButtonSize.height)

        strokeColorButton.frame = CGRect(x: 236, y: toolY, width: 48, height: 34)

        undoButton.frame = CGRect(x: bounds.width - 250, y: 14, width: toolButtonSize.width, height: toolButtonSize.height)
        redoButton.frame = CGRect(x: bounds.width - 210, y: 14, width: toolButtonSize.width, height: toolButtonSize.height)
        clearButton.frame = CGRect(x: bounds.width - 170, y: 14, width: toolButtonSize.width, height: toolButtonSize.height)
        cancelButton.frame = CGRect(x: bounds.width - 90, y: 14, width: toolButtonSize.width, height: toolButtonSize.height)
        doneButton.frame = CGRect(x: bounds.width - 50, y: 14, width: toolButtonSize.width, height: toolButtonSize.height)
    }

    func setTool(_ tool: ToolMode) {
        selectedTool = tool
        titleLabel.stringValue = tool.description

        let buttonsByTool: [(ToolMode, NSButton)] = [
            (.arrow, arrowToolButton),
            (.rectangle, rectangleToolButton),
            (.ellipse, ellipseToolButton),
            (.freeform, freeformToolButton),
            (.crop, cropToolButton),
        ]

        for (mode, button) in buttonsByTool {
            button.isBordered = mode == tool
            button.contentTintColor = mode == tool ? .controlAccentColor : .secondaryLabelColor
        }
    }

    func setUndoRedoState(canUndo: Bool, canRedo: Bool) {
        undoButton.isEnabled = canUndo
        redoButton.isEnabled = canRedo
        undoButton.alphaValue = canUndo ? 1 : 0.45
        redoButton.alphaValue = canRedo ? 1 : 0.45
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
    private func selectCropTool() {
        setTool(.crop)
        onToolChange(.crop)
    }

    private func configureMenus() {
        strokeColorButton.menu = makeColorMenu(options: strokeColorOptions, selector: #selector(selectStrokeColor(_:)))
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
        selectColorOption(option, on: strokeColorButton)
        onStrokeColorChange(option.color)
    }

    private func selectColorOption(_ option: ColorOption, on button: NSPopUpButton) {
        button.image = option.color.quickEyeMenuSwatchImage
        button.title = ""
        button.toolTip = "\(option.name) stroke color"
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
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.bezelStyle = .rounded
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityLabel)
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        button.title = ""
        button.toolTip = accessibilityLabel
        return button
    }
}
