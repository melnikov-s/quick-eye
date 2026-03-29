import AppKit
import Carbon

final class AnnotationCanvasView: NSView {
    private static let maxExportLongEdge: CGFloat = 1800
    private static let annotationOutlineOuterColor = NSColor.black.withAlphaComponent(0.9)
    private static let annotationOutlineInnerColor = NSColor.white.withAlphaComponent(0.98)
    private static let textBubbleBackgroundColor = NSColor.black.withAlphaComponent(0.84)
    private static let textBubbleBorderColor = NSColor.white.withAlphaComponent(0.18)
    private static let textBubbleHorizontalPadding: CGFloat = 12
    private static let textBubbleVerticalPadding: CGFloat = 8
    private static let textBubbleOffset: CGFloat = 12
    private static let textBubbleSafeInset: CGFloat = 16
    private static let textBubblePreferredMaxWidth: CGFloat = 360
    private static let textBubbleExpandedMaxWidth: CGFloat = 460
    private static let textBubbleFontSizes: [CGFloat] = [18, 16, 14, 13]
    private static let textBubbleCollisionPadding: CGFloat = 10

    private struct TextBubbleLayout {
        let bubbleRect: CGRect
        let textRect: CGRect
        let attributedText: NSAttributedString
    }

    private enum AnnotationElement: Equatable {
        case shape
        case label
    }

    private struct SelectionTarget: Equatable {
        let annotationID: UUID
        let element: AnnotationElement
    }

    private let screenshot: NSImage
    private let defaultExportRect: CGRect
    private let onComplete: (NSImage, AnnotationHistoryPayload?) -> Void
    private let onConvertToText: (NSImage, AnnotationHistoryPayload?, @escaping (Result<Void, Swift.Error>) -> Void) -> Void
    private let onCancel: (AnnotationHistoryPayload?) -> Void

    private var annotations: [CanvasAnnotation] = []
    private var pendingAnnotation: CanvasAnnotation?
    private var dragStartPoint: CGPoint?
    private var dragCurrentPoint: CGPoint?
    private var freeformPoints: [CGPoint] = []
    private var toolMode: ToolMode = .arrow
    private var annotationStyle: AnnotationStyle = .default
    private var autoAttachLabel = true
    private var isAwaitingManualCrop = false
    private var isGeneratingTextPrompt = false
    private var selectedTarget: SelectionTarget?
    private var movingTarget: SelectionTarget?
    private var moveStartPoint: CGPoint?
    private var moveOriginalAnnotation: CanvasAnnotation?
    private var hasRecordedMoveSnapshot = false

    private var undoStack: [AnnotationSnapshot] = []
    private var redoStack: [AnnotationSnapshot] = []

    private lazy var hudView: CaptureHUDView = {
        let view = CaptureHUDView(
            onDone: { [weak self] in
                self?.finishCapture(autoCrop: false)
            },
            onDoneAutoCrop: { [weak self] in
                self?.finishCapture(autoCrop: true)
            },
            onDoneManualCrop: { [weak self] in
                self?.beginManualCropExport()
            },
            onDoneConvertToText: { [weak self] in
                self?.convertCaptureToText()
            },
            onDiscard: { [weak self] in
                self?.discardCapture()
            },
            onUndo: { [weak self] in
                self?.undoLastChange()
            },
            onRedo: { [weak self] in
                self?.redoLastChange()
            },
            onToolChange: { [weak self] mode in
                self?.selectTool(mode)
            },
            onStrokeColorChange: { [weak self] color in
                self?.annotationStyle.strokeColor = color
                self?.needsDisplay = true
            },
            onAutoLabelChange: { [weak self] isEnabled in
                self?.autoAttachLabel = isEnabled
            }
        )
        return view
    }()

    private var activeEditor: AnnotationInputView?

    init(
        frame: CGRect,
        screenshot: NSImage,
        defaultExportRect: CGRect,
        initialState: AnnotationHistoryState? = nil,
        onComplete: @escaping (NSImage, AnnotationHistoryPayload?) -> Void,
        onConvertToText: @escaping (NSImage, AnnotationHistoryPayload?, @escaping (Result<Void, Swift.Error>) -> Void) -> Void,
        onCancel: @escaping (AnnotationHistoryPayload?) -> Void
    ) {
        self.screenshot = screenshot
        self.defaultExportRect = defaultExportRect
        self.onComplete = onComplete
        self.onConvertToText = onConvertToText
        self.onCancel = onCancel
        super.init(frame: frame)
        wantsLayer = true

        if let initialState {
            annotations = initialState.snapshot.annotations
            undoStack = initialState.undoStack
            redoStack = initialState.redoStack
            toolMode = initialState.toolMode
            annotationStyle = initialState.annotationStyle
            autoAttachLabel = initialState.autoAttachLabel
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if hudView.superview == nil {
            addSubview(hudView)
        }

        let size = hudView.fittingSize
        hudView.frame = CGRect(
            x: bounds.maxX - size.width - 24,
            y: bounds.maxY - size.height - 24,
            width: size.width,
            height: size.height
        )
        refreshHUDState()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        screenshot.draw(in: bounds)
        drawBaseOverlay()
        let bubbleLayouts = currentTextBubbleLayouts()

        annotations.forEach { annotation in
            drawAnnotation(
                annotation,
                bubbleLayout: bubbleLayouts[annotation.id],
                showsSelectionOutline: true
            )
        }

        if let pendingAnnotation {
            drawAnnotation(
                pendingAnnotation,
                isDraft: true,
                bubbleLayout: bubbleLayouts[pendingAnnotation.id],
                showsSelectionOutline: true
            )
        } else {
            drawLivePreview()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard activeEditor == nil, !isGeneratingTextPrompt else { return }

        let point = convert(event.locationInWindow, from: nil)

        if isAwaitingManualCrop {
            selectedTarget = nil
            resetDragState()
            dragStartPoint = point
            dragCurrentPoint = point
            needsDisplay = true
            return
        }

        if let hitTarget = selectionTarget(at: point),
           let hitAnnotation = annotation(withID: hitTarget.annotationID) {
            selectedTarget = hitTarget
            if event.clickCount >= 2, hitTarget.element == .label {
                presentEditor(
                    for: hitAnnotation,
                    initialText: hitAnnotation.text,
                    submitButtonTitle: "Save",
                    onSubmit: { [weak self] text in
                        self?.updateAnnotationText(id: hitAnnotation.id, text: text)
                    }
                )
                needsDisplay = true
                return
            }
            movingTarget = hitTarget
            moveStartPoint = point
            moveOriginalAnnotation = hitAnnotation
            hasRecordedMoveSnapshot = false
            needsDisplay = true
            return
        }

        selectedTarget = nil
        dragStartPoint = point
        dragCurrentPoint = point

        if toolMode == .freeform {
            freeformPoints = [point]
        }

        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isGeneratingTextPrompt else { return }
        let point = convert(event.locationInWindow, from: nil)

        if isAwaitingManualCrop {
            guard dragStartPoint != nil else { return }
            dragCurrentPoint = point
            needsDisplay = true
            return
        }

        if let movingTarget, let moveStartPoint, let moveOriginalAnnotation {
            let delta = point - moveStartPoint
            if !hasRecordedMoveSnapshot, abs(delta.width) + abs(delta.height) > 2 {
                registerSnapshot()
                hasRecordedMoveSnapshot = true
            }

            if let index = annotationIndex(for: movingTarget.annotationID) {
                annotations[index] = translatedAnnotation(
                    moveOriginalAnnotation,
                    moving: movingTarget.element,
                    by: delta
                )
                selectedTarget = movingTarget
                refreshHUDState()
                needsDisplay = true
            }
            return
        }

        guard dragStartPoint != nil else { return }
        dragCurrentPoint = point

        if toolMode == .freeform {
            freeformPoints.append(point)
        }

        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard !isGeneratingTextPrompt else { return }
        if isAwaitingManualCrop {
            let endPoint = convert(event.locationInWindow, from: nil)
            finishManualCropIfPossible(endingAt: endPoint)
            return
        }

        if movingTarget != nil {
            movingTarget = nil
            moveStartPoint = nil
            moveOriginalAnnotation = nil
            hasRecordedMoveSnapshot = false
            needsDisplay = true
            return
        }

        guard let annotation = makeAnnotationFromCurrentDrag(
            endingAt: convert(event.locationInWindow, from: nil)
        ) else {
            resetDragState()
            needsDisplay = true
            return
        }

        resetDragState()

        if shouldPresentEditorImmediately(for: annotation) {
            pendingAnnotation = annotation
            presentEditor(
                for: annotation,
                initialText: "",
                submitButtonTitle: "Add",
                onSubmit: { [weak self] text in
                    self?.commitPendingAnnotation(text: text)
                }
            )
        } else {
            registerSnapshot()
            annotations.append(annotation)
            selectedTarget = SelectionTarget(annotationID: annotation.id, element: .shape)
            refreshHUDState()
        }

        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if activeEditor != nil {
            super.keyDown(with: event)
            return
        }

        if isGeneratingTextPrompt {
            if event.keyCode == UInt16(kVK_Escape) {
                cancelCapture()
            } else {
                super.keyDown(with: event)
            }
            return
        }

        if isAwaitingManualCrop {
            if event.keyCode == UInt16(kVK_Escape) {
                cancelCapture()
            } else {
                super.keyDown(with: event)
            }
            return
        }

        let characters = event.charactersIgnoringModifiers?.lowercased()
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
           characters == "z" {
            if event.modifierFlags.contains(.shift) {
                redoLastChange()
            } else {
                undoLastChange()
            }
            return
        }

        if isDeleteKey(event.keyCode) {
            deleteSelectedAnnotation()
            return
        }

        if isReturnKey(event.keyCode) {
            if event.modifierFlags.contains(.command) && event.modifierFlags.contains(.shift) {
                beginManualCropExport()
            } else if event.modifierFlags.contains(.command) {
                convertCaptureToText()
            } else if event.modifierFlags.contains(.shift) {
                finishCapture(autoCrop: true)
            } else {
                finishCapture(autoCrop: false)
            }
            return
        }

        if event.keyCode == UInt16(kVK_Escape) {
            cancelCapture()
            return
        }

        super.keyDown(with: event)
    }

    private func makeAnnotationFromCurrentDrag(endingAt endPoint: CGPoint) -> CanvasAnnotation? {
        guard let start = dragStartPoint else { return nil }

        switch toolMode {
        case .arrow:
            let annotation = CanvasAnnotation(
                id: UUID(),
                kind: .arrow(start: start, end: endPoint),
                text: "",
                textOrigin: nil,
                style: annotationStyle
            )
            return annotation.kind.isSubstantial ? annotation : nil
        case .rectangle:
            let rect = rect(from: start, to: endPoint)
            let annotation = CanvasAnnotation(
                id: UUID(),
                kind: .rectangle(rect),
                text: "",
                textOrigin: nil,
                style: annotationStyle
            )
            return annotation.kind.isSubstantial ? annotation : nil
        case .ellipse:
            let rect = rect(from: start, to: endPoint)
            let annotation = CanvasAnnotation(
                id: UUID(),
                kind: .ellipse(rect),
                text: "",
                textOrigin: nil,
                style: annotationStyle
            )
            return annotation.kind.isSubstantial ? annotation : nil
        case .freeform:
            var points = freeformPoints
            if points.last != endPoint {
                points.append(endPoint)
            }
            let annotation = CanvasAnnotation(
                id: UUID(),
                kind: .freeform(points),
                text: "",
                textOrigin: nil,
                style: annotationStyle
            )
            return annotation.kind.isSubstantial ? annotation : nil
        case .label:
            return CanvasAnnotation(
                id: UUID(),
                kind: .label(endPoint),
                text: "",
                textOrigin: nil,
                style: annotationStyle
            )
        }
    }

    private func presentEditor(
        for annotation: CanvasAnnotation,
        initialText: String,
        submitButtonTitle: String,
        onSubmit: @escaping (String) -> Void
    ) {
        activeEditor?.removeFromSuperview()

        let editor = AnnotationInputView(
            initialText: initialText,
            submitButtonTitle: submitButtonTitle,
            onSubmit: onSubmit,
            onCancel: { [weak self] in
                self?.discardPendingAnnotation()
            }
        )

        let desiredSize = CGSize(width: 320, height: 110)
        let editorAnchor = editorAnchorPoint(for: annotation)
        let origin = clampedEditorOrigin(near: editorAnchor, size: desiredSize)
        editor.frame = CGRect(origin: origin, size: desiredSize)
        editor.onPreferredHeightChange = { [weak self, weak editor] (newHeight: CGFloat) in
            guard let self, let editor else { return }

            let newSize = CGSize(width: editor.frame.width, height: newHeight)
            let newOrigin = self.clampedEditorOrigin(near: editorAnchor, size: newSize)
            editor.frame = CGRect(origin: newOrigin, size: newSize)
        }

        addSubview(editor)
        activeEditor = editor
        editor.focus()
    }

    private func commitPendingAnnotation(text: String) {
        guard var pendingAnnotation else { return }
        if text.isEmpty, case .label = pendingAnnotation.kind {
            discardPendingAnnotation()
            return
        }
        registerSnapshot()
        pendingAnnotation.text = text
        pendingAnnotation.textOrigin = text.isEmpty ? nil : initialTextOrigin(for: pendingAnnotation, text: text)
        annotations.append(pendingAnnotation)
        selectedTarget = SelectionTarget(
            annotationID: pendingAnnotation.id,
            element: selectionElement(for: pendingAnnotation)
        )
        self.pendingAnnotation = nil
        removeEditor()
        refreshHUDState()
        needsDisplay = true
    }

    private func updateAnnotationText(id: UUID, text: String) {
        guard let index = annotationIndex(for: id) else { return }
        registerSnapshot()
        annotations[index].text = text
        if text.isEmpty {
            if case .label = annotations[index].kind {
                annotations.remove(at: index)
                selectedTarget = nil
            } else {
                annotations[index].textOrigin = nil
                selectedTarget = SelectionTarget(annotationID: id, element: .shape)
            }
        } else {
            annotations[index].textOrigin = annotations[index].textOrigin ?? initialTextOrigin(for: annotations[index], text: text)
            selectedTarget = SelectionTarget(annotationID: id, element: .label)
        }
        pendingAnnotation = nil
        removeEditor()
        refreshHUDState()
        needsDisplay = true
    }

    private func discardPendingAnnotation() {
        pendingAnnotation = nil
        removeEditor()
        refreshHUDState()
        needsDisplay = true
    }

    private func shouldPresentEditorImmediately(for annotation: CanvasAnnotation) -> Bool {
        switch annotation.kind {
        case .label:
            return true
        default:
            return autoAttachLabel
        }
    }

    private func selectionElement(for annotation: CanvasAnnotation) -> AnnotationElement {
        switch annotation.kind {
        case .label:
            return .label
        default:
            return annotation.text.isEmpty ? .shape : .label
        }
    }

    private func removeEditor() {
        activeEditor?.removeFromSuperview()
        activeEditor = nil
        window?.makeFirstResponder(self)
    }

    private func selectTool(_ mode: ToolMode) {
        toolMode = mode
        isAwaitingManualCrop = false
        resetDragState()
        refreshHUDState()
        needsDisplay = true
    }

    private func discardCapture() {
        guard !isGeneratingTextPrompt else { return }
        annotations.removeAll()
        pendingAnnotation = nil
        isAwaitingManualCrop = false
        selectedTarget = nil
        undoStack.removeAll()
        redoStack.removeAll()
        resetDragState()
        removeEditor()
        onCancel(nil)
    }

    private func undoLastChange() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(currentSnapshot())
        apply(snapshot: previous)
    }

    private func redoLastChange() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(currentSnapshot())
        apply(snapshot: next)
    }

    private func registerSnapshot() {
        undoStack.append(currentSnapshot())
        redoStack.removeAll()
        refreshHUDState()
    }

    private func currentSnapshot() -> AnnotationSnapshot {
        AnnotationSnapshot(annotations: annotations)
    }

    private func apply(snapshot: AnnotationSnapshot) {
        annotations = snapshot.annotations
        pendingAnnotation = nil
        isAwaitingManualCrop = false
        selectedTarget = nil
        removeEditor()
        refreshHUDState()
        needsDisplay = true
    }

    private func refreshHUDState() {
        hudView.setTool(toolMode)
        hudView.setAutoLabelEnabled(autoAttachLabel)
        let statusMessage: String?
        if isGeneratingTextPrompt {
            statusMessage = "Generating text prompt..."
        } else if isAwaitingManualCrop {
            statusMessage = "Manual crop: drag a frame to crop, copy, and finish."
        } else {
            statusMessage = nil
        }
        hudView.setStatusMessage(statusMessage)
        hudView.setBusyState(isBusy: isGeneratingTextPrompt, message: statusMessage)
        hudView.setUndoRedoState(canUndo: !undoStack.isEmpty, canRedo: !redoStack.isEmpty)
    }

    private func cancelCapture() {
        pendingAnnotation = nil
        isAwaitingManualCrop = false
        resetDragState()
        removeEditor()
        onCancel(historyPayloadForPersistence())
    }

    private func drawLivePreview() {
        if let manualCropRect = currentManualCropRect {
            drawCropOverlay(rect: manualCropRect, isDraft: true)
            return
        }

        switch toolMode {
        case .freeform:
            if freeformPoints.count > 1 {
                drawFreeform(points: freeformPoints, style: annotationStyle, isDraft: true)
            }
        case .arrow, .rectangle, .ellipse, .label:
            guard let draftAnnotation = draftAnnotationFromDrag() else { return }
            drawAnnotation(draftAnnotation, isDraft: true)
        }
    }

    private func draftAnnotationFromDrag() -> CanvasAnnotation? {
        guard let start = dragStartPoint, let end = dragCurrentPoint else { return nil }

        switch toolMode {
        case .arrow:
            return CanvasAnnotation(id: UUID(), kind: .arrow(start: start, end: end), text: "", textOrigin: nil, style: annotationStyle)
        case .rectangle:
            return CanvasAnnotation(id: UUID(), kind: .rectangle(rect(from: start, to: end)), text: "", textOrigin: nil, style: annotationStyle)
        case .ellipse:
            return CanvasAnnotation(id: UUID(), kind: .ellipse(rect(from: start, to: end)), text: "", textOrigin: nil, style: annotationStyle)
        case .label:
            return CanvasAnnotation(id: UUID(), kind: .label(end), text: "Label", textOrigin: nil, style: annotationStyle)
        case .freeform:
            return nil
        }
    }

    private func drawAnnotation(
        _ annotation: CanvasAnnotation,
        isDraft: Bool = false,
        bubbleLayout: TextBubbleLayout? = nil,
        showsSelectionOutline: Bool = false
    ) {
        switch annotation.kind {
        case let .arrow(start, end):
            drawArrow(
                from: start,
                to: end,
                text: annotation.text,
                style: annotation.style,
                isDraft: isDraft,
                textBubbleLayout: bubbleLayout
            )
        case let .rectangle(rect):
            drawRectangularShape(
                rect: rect,
                anchor: CGPoint(x: rect.maxX, y: rect.maxY),
                text: annotation.text,
                style: annotation.style,
                isDraft: isDraft,
                makePath: { NSBezierPath(rect: $0) },
                textBubbleLayout: bubbleLayout
            )
        case let .ellipse(rect):
            drawRectangularShape(
                rect: rect,
                anchor: CGPoint(x: rect.maxX, y: rect.maxY),
                text: annotation.text,
                style: annotation.style,
                isDraft: isDraft,
                makePath: { NSBezierPath(ovalIn: $0) },
                textBubbleLayout: bubbleLayout
            )
        case let .freeform(points):
            drawFreeform(points: points, style: annotation.style, isDraft: isDraft)
            if !annotation.text.isEmpty {
                drawTextBubble(
                    bubbleLayout ?? textBubbleLayout(for: annotation),
                    anchor: annotation.textAnchor,
                    style: annotation.style
                )
            }
        case .label:
            guard !annotation.text.isEmpty else { break }
            drawTextBubble(
                bubbleLayout ?? textBubbleLayout(for: annotation),
                anchor: nil,
                style: annotation.style
            )
        }

        if showsSelectionOutline, selectedTarget?.annotationID == annotation.id {
            drawSelectionOutline(for: annotation, target: selectedTarget)
        }
    }

    private func drawArrow(
        from start: CGPoint,
        to end: CGPoint,
        text: String,
        style: AnnotationStyle,
        isDraft: Bool,
        textBubbleLayout: TextBubbleLayout?
    ) {
        let shaftLength = start.distance(to: end)
        let minimumLengthToRenderArrow: CGFloat = 6
        guard shaftLength >= minimumLengthToRenderArrow else { return }

        let shaft = NSBezierPath()
        shaft.move(to: start)
        shaft.line(to: end)
        shaft.lineCapStyle = .round
        strokeAnnotationPath(shaft, color: style.strokeColor, lineWidth: isDraft ? 5 : 4)

        let arrowLength: CGFloat = 16
        let arrowAngle: CGFloat = .pi / 8
        let angle = atan2(start.y - end.y, start.x - end.x)
        let leftPoint = CGPoint(
            x: start.x - arrowLength * cos(angle - arrowAngle),
            y: start.y - arrowLength * sin(angle - arrowAngle)
        )
        let rightPoint = CGPoint(
            x: start.x - arrowLength * cos(angle + arrowAngle),
            y: start.y - arrowLength * sin(angle + arrowAngle)
        )

        let head = NSBezierPath()
        head.move(to: start)
        head.line(to: leftPoint)
        head.move(to: start)
        head.line(to: rightPoint)
        head.lineCapStyle = .round
        strokeAnnotationPath(head, color: style.strokeColor, lineWidth: 4)

        if !text.isEmpty {
            drawTextBubble(
                textBubbleLayout ?? self.textBubbleLayout(text: text, near: end),
                anchor: end,
                style: style
            )
        }
    }

    private func drawRectangularShape(
        rect: CGRect,
        anchor: CGPoint,
        text: String,
        style: AnnotationStyle,
        isDraft: Bool,
        makePath: (CGRect) -> NSBezierPath,
        textBubbleLayout: TextBubbleLayout?
    ) {
        let path = makePath(rect)
        let dash: [CGFloat] = isDraft ? [8, 5] : []
        if !dash.isEmpty {
            path.setLineDash(dash, count: dash.count, phase: 0)
        }
        strokeAnnotationPath(path, color: style.strokeColor, lineWidth: isDraft ? 5 : 4)

        if !text.isEmpty {
            drawTextBubble(
                textBubbleLayout ?? self.textBubbleLayout(text: text, near: anchor),
                anchor: anchor,
                style: style
            )
        }
    }

    private func drawFreeform(points: [CGPoint], style: AnnotationStyle, isDraft: Bool) {
        guard let first = points.first else { return }

        let path = NSBezierPath()
        path.move(to: first)
        for point in points.dropFirst() {
            path.line(to: point)
        }
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        strokeAnnotationPath(path, color: style.strokeColor, lineWidth: isDraft ? 5 : 4)
    }

    private func drawTextBubble(_ layout: TextBubbleLayout, anchor point: CGPoint?, style: AnnotationStyle) {
        let rect = layout.bubbleRect
        if let point,
           let connectorPoint = closestPoint(on: rect, to: point),
           point.distance(to: connectorPoint) > 10 {
            let connector = NSBezierPath()
            connector.move(to: point)
            connector.line(to: connectorPoint)
            connector.lineCapStyle = .round
            let dash: [CGFloat] = [6, 4]
            connector.setLineDash(dash, count: dash.count, phase: 0)
            strokeAnnotationPath(connector, color: style.strokeColor, lineWidth: 2.5)
        }

        let background = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
        Self.textBubbleBackgroundColor.setFill()
        background.fill()
        Self.textBubbleBorderColor.setStroke()
        background.lineWidth = 1
        background.stroke()
        layout.attributedText.draw(
            with: layout.textRect,
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
    }

    private func strokeAnnotationPath(_ path: NSBezierPath, color: NSColor, lineWidth: CGFloat) {
        path.lineWidth = lineWidth + 4
        Self.annotationOutlineOuterColor.setStroke()
        path.stroke()

        path.lineWidth = lineWidth + 2
        Self.annotationOutlineInnerColor.setStroke()
        path.stroke()

        path.lineWidth = lineWidth
        color.setStroke()
        path.stroke()
    }

    private func drawSelectionOutline(for annotation: CanvasAnnotation, target: SelectionTarget?) {
        let bounds: CGRect?
        switch target?.element {
        case .label:
            bounds = textBubbleRect(for: annotation)
        case .shape, .none:
            bounds = shapeBounds(for: annotation.kind)
        }

        guard let bounds, !bounds.isNull else { return }

        let outlineRect = bounds.insetBy(dx: -8, dy: -8)
        let path = NSBezierPath(roundedRect: outlineRect, xRadius: 10, yRadius: 10)
        let dash: [CGFloat] = [7, 5]
        path.setLineDash(dash, count: dash.count, phase: 0)
        path.lineWidth = 2
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }

    private func finishCapture(autoCrop: Bool) {
        guard !isGeneratingTextPrompt else { return }
        isAwaitingManualCrop = false
        pendingAnnotation = nil
        removeEditor()

        onComplete(finalizedExportImage(autoCrop: autoCrop), historyPayloadForPersistence())
    }

    private func resolvedExportCropRect(autoCrop: Bool) -> CGRect? {
        let preferredExportRect = expandedPreferredExportRect()

        if autoCrop {
            if let cropRect = autoCropRect()?.intersection(preferredExportRect) {
                return cropRect
            }

            return preferredExportRect == bounds ? nil : preferredExportRect
        }

        guard preferredExportRect != bounds else { return nil }
        return preferredExportRect
    }

    private func beginManualCropExport() {
        guard activeEditor == nil, !isGeneratingTextPrompt else { return }

        pendingAnnotation = nil
        selectedTarget = nil
        isAwaitingManualCrop = true
        resetDragState()
        refreshHUDState()
        needsDisplay = true
    }

    private func finishManualCropIfPossible(endingAt endPoint: CGPoint) {
        dragCurrentPoint = endPoint
        guard let cropRect = currentManualCropRect, cropRect.width > 10, cropRect.height > 10 else {
            dragStartPoint = nil
            dragCurrentPoint = nil
            needsDisplay = true
            return
        }

        isAwaitingManualCrop = false
        let exportImage = rasterizedAnnotatedImage()
        let finalizedImage = croppedImage(from: exportImage, cropRect: cropRect)
        let historyPayload = historyPayloadForPersistence()
        resetDragState()
        refreshHUDState()
        onComplete(downscaledImageIfNeeded(from: finalizedImage), historyPayload)
    }

    private func convertCaptureToText() {
        guard !isGeneratingTextPrompt else { return }

        pendingAnnotation = nil
        removeEditor()
        isAwaitingManualCrop = false
        isGeneratingTextPrompt = true
        resetDragState()
        refreshHUDState()
        needsDisplay = true

        onConvertToText(finalizedExportImage(autoCrop: false), historyPayloadForPersistence()) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                if case .failure = result {
                    self.isGeneratingTextPrompt = false
                    self.refreshHUDState()
                    self.needsDisplay = true
                }
            }
        }
    }

    private func finalizedExportImage(autoCrop: Bool) -> NSImage {
        let exportImage = rasterizedAnnotatedImage()
        let finalizedImage: NSImage
        if let exportCropRect = resolvedExportCropRect(autoCrop: autoCrop) {
            finalizedImage = croppedImage(from: exportImage, cropRect: exportCropRect)
        } else {
            finalizedImage = exportImage
        }

        return downscaledImageIfNeeded(from: finalizedImage)
    }

    private func autoCropRect() -> CGRect? {
        let allBounds = annotations
            .compactMap(autoCropBounds(_:))
            .reduce(into: CGRect.null) { partial, rect in
                partial = partial.union(rect)
            }

        guard !allBounds.isNull else { return nil }

        let padding: CGFloat = 28
        let padded = allBounds.insetBy(dx: -padding, dy: -padding)
        return padded.intersection(bounds)
    }

    private func expandedPreferredExportRect() -> CGRect {
        let baseRect = defaultExportRect.intersection(bounds)
        guard !baseRect.isNull, baseRect.width > 0, baseRect.height > 0 else {
            return bounds
        }

        let expanded = annotations.reduce(into: baseRect) { partial, annotation in
            guard let annotationBounds = annotationBounds(annotation),
                  !baseRect.contains(annotationBounds) else {
                return
            }

            partial = partial.union(exportExpansionBounds(for: annotation) ?? annotationBounds)
        }

        if let pendingAnnotation,
           let annotationBounds = annotationBounds(pendingAnnotation),
           !baseRect.contains(annotationBounds) {
            return expanded.union(exportExpansionBounds(for: pendingAnnotation) ?? annotationBounds)
        }

        return expanded.intersection(bounds)
    }

    private func exportExpansionBounds(for annotation: CanvasAnnotation) -> CGRect? {
        guard let annotationBounds = annotationBounds(annotation) else { return nil }

        if defaultExportRect.contains(annotationBounds) {
            return annotationBounds
        }

        return autoCropBounds(annotation) ?? annotationBounds
    }

    private func rasterizedAnnotatedImage() -> NSImage {
        let image = NSImage(size: bounds.size)
        image.lockFocus()
        screenshot.draw(in: bounds)
        let bubbleLayouts = currentTextBubbleLayouts()
        annotations.forEach { annotation in
            drawAnnotation(
                annotation,
                bubbleLayout: bubbleLayouts[annotation.id],
                showsSelectionOutline: false
            )
        }
        image.unlockFocus()
        return image
    }

    private func croppedImage(from image: NSImage, cropRect: CGRect) -> NSImage {
        let normalizedCrop = cropRect.intersection(bounds)
        guard !normalizedCrop.isNull, normalizedCrop.width > 0, normalizedCrop.height > 0 else {
            return image
        }

        let cropped = NSImage(size: normalizedCrop.size)
        cropped.lockFocus()
        image.draw(
            at: CGPoint(x: -normalizedCrop.minX, y: -normalizedCrop.minY),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        cropped.unlockFocus()
        return cropped
    }

    private func downscaledImageIfNeeded(from image: NSImage) -> NSImage {
        let originalSize = image.size
        let longEdge = max(originalSize.width, originalSize.height)

        guard longEdge > Self.maxExportLongEdge, longEdge > 0 else {
            return image
        }

        let scale = Self.maxExportLongEdge / longEdge
        let targetSize = CGSize(
            width: max(1, floor(originalSize.width * scale)),
            height: max(1, floor(originalSize.height * scale))
        )

        let downscaled = NSImage(size: targetSize)
        downscaled.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: CGRect(origin: .zero, size: targetSize),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        downscaled.unlockFocus()
        return downscaled
    }

    private func drawBaseOverlay() {
        if let manualCropRect = currentManualCropRect {
            let dimmedArea = NSBezierPath(rect: bounds)
            dimmedArea.append(NSBezierPath(rect: manualCropRect))
            dimmedArea.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.34).setFill()
            dimmedArea.fill()
            return
        }

        if !isAwaitingManualCrop {
            NSColor.black.withAlphaComponent(0.08).setFill()
            bounds.fill()
            return
        }

        NSColor.black.withAlphaComponent(0.18).setFill()
        bounds.fill()
    }

    private func drawCropOverlay(rect: CGRect, isDraft: Bool) {
        let border = NSBezierPath(rect: rect)
        border.lineWidth = isDraft ? 3 : 2
        let dash: [CGFloat] = [8, 6]
        border.setLineDash(dash, count: dash.count, phase: 0)
        NSColor.white.setStroke()
        border.stroke()
    }

    private var currentManualCropRect: CGRect? {
        guard isAwaitingManualCrop,
              let start = dragStartPoint,
              let end = dragCurrentPoint else { return nil }
        return rect(from: start, to: end)
    }

    private func clampedEditorOrigin(near point: CGPoint, size: CGSize) -> CGPoint {
        let padding: CGFloat = 16
        var origin = CGPoint(x: point.x + 12, y: point.y - size.height - 12)
        origin.x = min(max(origin.x, padding), bounds.maxX - size.width - padding)
        origin.y = min(max(origin.y, padding), bounds.maxY - size.height - padding)
        return origin
    }

    private func editorAnchorPoint(for annotation: CanvasAnnotation) -> CGPoint {
        if let bubbleRect = textBubbleRect(for: annotation) {
            return CGPoint(x: bubbleRect.minX, y: bubbleRect.maxY)
        }

        return annotation.textOrigin ?? annotation.textAnchor
    }

    private func rect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    private func annotationBounds(_ annotation: CanvasAnnotation) -> CGRect? {
        let shapeBounds = shapeBounds(for: annotation.kind)
        let bubbleBounds = textBubbleRect(for: annotation)

        if shapeBounds.isNull {
            return bubbleBounds
        }

        guard let bubbleBounds else {
            return shapeBounds
        }

        return shapeBounds.union(bubbleBounds)
    }

    private func autoCropBounds(_ annotation: CanvasAnnotation) -> CGRect? {
        guard var bounds = annotationBounds(annotation) else { return nil }

        if case let .arrow(target, tail) = annotation.kind {
            bounds = bounds
                .union(arrowTargetFocusRect(target: target, tail: tail))
                .union(arrowSourceFocusRect(target: target, tail: tail))
        }

        return bounds
    }

    private func shapeBounds(for kind: AnnotationKind) -> CGRect {
        switch kind {
        case let .arrow(start, end):
            let lineRect = rect(from: start, to: end)
            return lineRect.insetBy(dx: -22, dy: -22)
        case let .rectangle(rect), let .ellipse(rect):
            return rect.insetBy(dx: -6, dy: -6)
        case let .freeform(points):
            return points.boundingRect.insetBy(dx: -6, dy: -6)
        case .label:
            return .null
        }
    }

    private func textBubbleRect(for annotation: CanvasAnnotation) -> CGRect? {
        guard !annotation.text.isEmpty else { return nil }
        return currentTextBubbleLayouts()[annotation.id]?.bubbleRect
    }

    private func textBubbleLayout(for annotation: CanvasAnnotation, occupiedRects: [CGRect] = []) -> TextBubbleLayout {
        textBubbleLayout(
            text: annotation.text,
            near: annotation.textAnchor,
            preferredOrigin: annotation.textOrigin,
            occupiedRects: occupiedRects
        )
    }

    private func textBubbleLayout(
        text: String,
        near point: CGPoint,
        preferredOrigin: CGPoint? = nil,
        occupiedRects: [CGRect] = []
    ) -> TextBubbleLayout {
        let safeBounds = bounds.insetBy(dx: Self.textBubbleSafeInset, dy: Self.textBubbleSafeInset)
        let absoluteMaxTextWidth = max(
            160,
            safeBounds.width - (Self.textBubbleHorizontalPadding * 2)
        )
        let candidateWidths = [
            min(Self.textBubblePreferredMaxWidth, absoluteMaxTextWidth),
            min(Self.textBubbleExpandedMaxWidth, absoluteMaxTextWidth),
            absoluteMaxTextWidth,
        ]
        let maxTextHeight = max(
            44,
            safeBounds.height - (Self.textBubbleVerticalPadding * 2) - 24
        )

        var fallbackLayout: TextBubbleLayout?

        for fontSize in Self.textBubbleFontSizes {
            for textWidth in candidateWidths {
                let layout = makeTextBubbleLayout(
                    text: text,
                    near: point,
                    preferredOrigin: preferredOrigin,
                    safeBounds: safeBounds,
                    fontSize: fontSize,
                    maxTextWidth: textWidth,
                    occupiedRects: occupiedRects
                )

                fallbackLayout = layout
                if layout.textRect.height <= maxTextHeight {
                    return layout
                }
            }
        }

        return fallbackLayout ?? makeTextBubbleLayout(
            text: text,
            near: point,
            preferredOrigin: preferredOrigin,
            safeBounds: safeBounds,
            fontSize: Self.textBubbleFontSizes.last ?? 13,
            maxTextWidth: absoluteMaxTextWidth,
            occupiedRects: occupiedRects
        )
    }

    private func makeTextBubbleLayout(
        text: String,
        near point: CGPoint,
        preferredOrigin: CGPoint?,
        safeBounds: CGRect,
        fontSize: CGFloat,
        maxTextWidth: CGFloat,
        occupiedRects: [CGRect]
    ) -> TextBubbleLayout {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraphStyle,
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let measuredTextBounds = attributed.boundingRect(
            with: CGSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let textSize = CGSize(
            width: ceil(min(maxTextWidth, max(measuredTextBounds.width, 1))),
            height: ceil(max(measuredTextBounds.height, fontSize))
        )
        let bubbleSize = CGSize(
            width: textSize.width + (Self.textBubbleHorizontalPadding * 2),
            height: textSize.height + (Self.textBubbleVerticalPadding * 2)
        )

        let bubbleOrigin: CGPoint
        if let preferredOrigin {
            bubbleOrigin = clampedBubbleOrigin(preferredOrigin, bubbleSize: bubbleSize, safeBounds: safeBounds)
        } else {
            bubbleOrigin = positionedTextBubbleOrigin(
                near: point,
                bubbleSize: bubbleSize,
                safeBounds: safeBounds,
                occupiedRects: occupiedRects
            )
        }
        let bubbleRect = CGRect(origin: bubbleOrigin, size: bubbleSize)
        let textRect = bubbleRect.insetBy(
            dx: Self.textBubbleHorizontalPadding,
            dy: Self.textBubbleVerticalPadding
        )

        return TextBubbleLayout(
            bubbleRect: bubbleRect,
            textRect: textRect,
            attributedText: attributed
        )
    }

    private func positionedTextBubbleOrigin(
        near point: CGPoint,
        bubbleSize: CGSize,
        safeBounds: CGRect,
        occupiedRects: [CGRect]
    ) -> CGPoint {
        let preferredOrigin = CGPoint(
            x: point.x + Self.textBubbleOffset,
            y: point.y + Self.textBubbleOffset
        )
        let candidateOrigins = candidateTextBubbleOrigins(near: point, bubbleSize: bubbleSize)

        var bestOrigin = clampedBubbleOrigin(preferredOrigin, bubbleSize: bubbleSize, safeBounds: safeBounds)
        var bestOverlap = overlapArea(
            for: CGRect(origin: bestOrigin, size: bubbleSize),
            occupiedRects: occupiedRects
        )
        var bestDistance = point.distance(to: bestOrigin)

        for origin in candidateOrigins {
            let clampedOrigin = clampedBubbleOrigin(origin, bubbleSize: bubbleSize, safeBounds: safeBounds)
            let candidateRect = CGRect(origin: clampedOrigin, size: bubbleSize)
            let overlap = overlapArea(for: candidateRect, occupiedRects: occupiedRects)
            let distance = preferredOrigin.distance(to: clampedOrigin)

            if overlap == 0 {
                return clampedOrigin
            }

            if overlap < bestOverlap || (overlap == bestOverlap && distance < bestDistance) {
                bestOrigin = clampedOrigin
                bestOverlap = overlap
                bestDistance = distance
            }
        }

        return bestOrigin
    }

    private func candidateTextBubbleOrigins(near point: CGPoint, bubbleSize: CGSize) -> [CGPoint] {
        let offset = Self.textBubbleOffset
        let centeredX = point.x - (bubbleSize.width / 2)
        let centeredY = point.y - (bubbleSize.height / 2)

        return [
            CGPoint(x: point.x + offset, y: point.y + offset),
            CGPoint(x: point.x - bubbleSize.width - offset, y: point.y + offset),
            CGPoint(x: point.x + offset, y: point.y - bubbleSize.height - offset),
            CGPoint(x: point.x - bubbleSize.width - offset, y: point.y - bubbleSize.height - offset),
            CGPoint(x: centeredX, y: point.y + offset),
            CGPoint(x: centeredX, y: point.y - bubbleSize.height - offset),
            CGPoint(x: point.x + offset, y: centeredY),
            CGPoint(x: point.x - bubbleSize.width - offset, y: centeredY),
        ]
    }

    private func clampedBubbleOrigin(
        _ origin: CGPoint,
        bubbleSize: CGSize,
        safeBounds: CGRect
    ) -> CGPoint {
        CGPoint(
            x: min(max(safeBounds.minX, origin.x), safeBounds.maxX - bubbleSize.width),
            y: min(max(safeBounds.minY, origin.y), safeBounds.maxY - bubbleSize.height)
        )
    }

    private func overlapArea(for candidateRect: CGRect, occupiedRects: [CGRect]) -> CGFloat {
        occupiedRects.reduce(0) { total, occupiedRect in
            let intersection = candidateRect.intersection(occupiedRect)
            guard !intersection.isNull else { return total }
            return total + (intersection.width * intersection.height)
        }
    }

    private func currentTextBubbleLayouts() -> [UUID: TextBubbleLayout] {
        var layouts: [UUID: TextBubbleLayout] = [:]
        var occupiedRects: [CGRect] = []

        let orderedAnnotations = annotations + (pendingAnnotation.map { [$0] } ?? [])
        for annotation in orderedAnnotations where !annotation.text.isEmpty {
            let layout = textBubbleLayout(for: annotation, occupiedRects: occupiedRects)
            layouts[annotation.id] = layout
            occupiedRects.append(
                layout.bubbleRect.insetBy(
                    dx: -Self.textBubbleCollisionPadding,
                    dy: -Self.textBubbleCollisionPadding
                )
            )
        }

        return layouts
    }

    private func initialTextOrigin(for annotation: CanvasAnnotation, text: String) -> CGPoint {
        textBubbleLayout(
            text: text,
            near: annotation.textAnchor,
            preferredOrigin: annotation.textOrigin,
            occupiedRects: currentOccupiedTextRects(excluding: annotation.id)
        ).bubbleRect.origin
    }

    private func currentOccupiedTextRects(excluding annotationID: UUID? = nil) -> [CGRect] {
        currentTextBubbleLayouts()
            .filter { entry in
                guard let annotationID else { return true }
                return entry.key != annotationID
            }
            .map { _, layout in
                layout.bubbleRect.insetBy(
                    dx: -Self.textBubbleCollisionPadding,
                    dy: -Self.textBubbleCollisionPadding
                )
            }
    }

    private func closestPoint(on rect: CGRect, to point: CGPoint) -> CGPoint? {
        guard !rect.isNull else { return nil }
        return CGPoint(
            x: min(max(point.x, rect.minX), rect.maxX),
            y: min(max(point.y, rect.minY), rect.maxY)
        )
    }

    private func arrowTargetFocusRect(target: CGPoint, tail: CGPoint) -> CGRect {
        let focusSize = CGSize(width: 180, height: 180)
        let halfSize = CGSize(width: focusSize.width / 2, height: focusSize.height / 2)

        var origin = CGPoint(
            x: target.x - halfSize.width,
            y: target.y - halfSize.height
        )

        let delta = target - tail
        let length = max(sqrt((delta.width * delta.width) + (delta.height * delta.height)), 1)
        let unit = CGSize(width: delta.width / length, height: delta.height / length)

        // Bias the target region slightly toward the thing being pointed at.
        origin.x += unit.width * 28
        origin.y += unit.height * 28

        let focusRect = CGRect(origin: origin, size: focusSize)
        return focusRect.intersection(bounds)
    }

    private func arrowSourceFocusRect(target: CGPoint, tail: CGPoint) -> CGRect {
        let focusSize = CGSize(width: 110, height: 110)
        let halfSize = CGSize(width: focusSize.width / 2, height: focusSize.height / 2)

        var origin = CGPoint(
            x: tail.x - halfSize.width,
            y: tail.y - halfSize.height
        )

        let delta = target - tail
        let length = max(sqrt((delta.width * delta.width) + (delta.height * delta.height)), 1)
        let unit = CGSize(width: delta.width / length, height: delta.height / length)

        // Bias the source region slightly away from the target so we keep context
        // around where the annotation text/tail originated.
        origin.x -= unit.width * 16
        origin.y -= unit.height * 16

        let focusRect = CGRect(origin: origin, size: focusSize)
        return focusRect.intersection(bounds)
    }

    private func resetDragState() {
        dragStartPoint = nil
        dragCurrentPoint = nil
        freeformPoints.removeAll()
        movingTarget = nil
        moveStartPoint = nil
        moveOriginalAnnotation = nil
        hasRecordedMoveSnapshot = false
    }

    private func isReturnKey(_ keyCode: UInt16) -> Bool {
        keyCode == UInt16(kVK_Return) || keyCode == 76
    }

    private func isDeleteKey(_ keyCode: UInt16) -> Bool {
        keyCode == UInt16(kVK_Delete) || keyCode == UInt16(kVK_ForwardDelete)
    }

    private func deleteSelectedAnnotation() {
        guard let selectedTarget,
              annotations.contains(where: { $0.id == selectedTarget.annotationID }) else { return }

        registerSnapshot()
        annotations.removeAll { $0.id == selectedTarget.annotationID }
        self.selectedTarget = nil
        refreshHUDState()
        needsDisplay = true
    }

    private func selectionTarget(at point: CGPoint) -> SelectionTarget? {
        for annotation in annotations.reversed() {
            if let target = selectionTarget(for: annotation, at: point) {
                return target
            }
        }
        return nil
    }

    private func selectionTarget(for annotation: CanvasAnnotation, at point: CGPoint) -> SelectionTarget? {
        if let bubbleRect = textBubbleRect(for: annotation), bubbleRect.contains(point) {
            return SelectionTarget(annotationID: annotation.id, element: .label)
        }

        guard annotationShapeContainsPoint(annotation, point: point) else {
            return nil
        }

        return SelectionTarget(annotationID: annotation.id, element: .shape)
    }

    private func annotationShapeContainsPoint(_ annotation: CanvasAnnotation, point: CGPoint) -> Bool {
        switch annotation.kind {
        case let .arrow(start, end):
            return distanceFromPoint(point, toSegmentStart: start, end: end) <= 18
        case let .rectangle(rect):
            return rect.insetBy(dx: -12, dy: -12).contains(point)
        case let .ellipse(rect):
            return rect.insetBy(dx: -12, dy: -12).contains(point)
        case let .freeform(points):
            return points.boundingRect.insetBy(dx: -12, dy: -12).contains(point)
        case .label:
            return false
        }
    }

    private func translatedAnnotation(
        _ annotation: CanvasAnnotation,
        moving element: AnnotationElement,
        by delta: CGSize
    ) -> CanvasAnnotation {
        var moved = annotation
        switch element {
        case .shape:
            switch annotation.kind {
            case let .arrow(start, end):
                moved.kind = .arrow(start: start + delta, end: end + delta)
            case let .rectangle(rect):
                moved.kind = .rectangle(rect.offsetBy(dx: delta.width, dy: delta.height))
            case let .ellipse(rect):
                moved.kind = .ellipse(rect.offsetBy(dx: delta.width, dy: delta.height))
            case let .freeform(points):
                moved.kind = .freeform(points.map { $0 + delta })
            case let .label(point):
                moved.kind = .label(point + delta)
                moved.textOrigin = (annotation.textOrigin ?? point) + delta
            }
        case .label:
            let currentOrigin = annotation.textOrigin ?? textBubbleRect(for: annotation)?.origin ?? annotation.textAnchor
            moved.textOrigin = currentOrigin + delta
        }
        return moved
    }

    private func annotation(withID id: UUID) -> CanvasAnnotation? {
        annotations.first(where: { $0.id == id })
    }

    private func annotationIndex(for id: UUID) -> Int? {
        annotations.firstIndex(where: { $0.id == id })
    }

    private func distanceFromPoint(_ point: CGPoint, toSegmentStart start: CGPoint, end: CGPoint) -> CGFloat {
        let segment = end - start
        let pointVector = point - start
        let segmentLengthSquared = (segment.width * segment.width) + (segment.height * segment.height)
        guard segmentLengthSquared > 0 else { return point.distance(to: start) }

        let projection = max(
            0,
            min(
                1,
                ((pointVector.width * segment.width) + (pointVector.height * segment.height)) / segmentLengthSquared
            )
        )

        let closest = CGPoint(
            x: start.x + segment.width * projection,
            y: start.y + segment.height * projection
        )
        return point.distance(to: closest)
    }

    private func historyPayloadForPersistence() -> AnnotationHistoryPayload? {
        guard !annotations.isEmpty else { return nil }

        let state = currentSessionState()
        return AnnotationHistoryPayload(state: state, previewImage: rasterizedAnnotatedImage())
    }

    private func currentSessionState() -> AnnotationHistoryState {
        AnnotationHistoryState(
            snapshot: currentSnapshot(),
            undoStack: undoStack,
            redoStack: redoStack,
            toolMode: toolMode,
            annotationStyle: annotationStyle,
            autoAttachLabel: autoAttachLabel
        )
    }
}
