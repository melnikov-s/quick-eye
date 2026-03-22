import AppKit
import Carbon

final class AnnotationCanvasView: NSView {
    private let screenshot: NSImage
    private let onComplete: (NSImage) -> Void
    private let onCancel: () -> Void

    private var annotations: [CanvasAnnotation] = []
    private var pendingAnnotation: CanvasAnnotation?
    private var dragStartPoint: CGPoint?
    private var dragCurrentPoint: CGPoint?
    private var freeformPoints: [CGPoint] = []
    private var toolMode: ToolMode = .arrow
    private var annotationStyle: AnnotationStyle = .default
    private var cropRect: CGRect?

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
            onCancel: { [weak self] in
                self?.cancelCapture()
            },
            onClear: { [weak self] in
                self?.clearCanvas()
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
            }
        )
        return view
    }()

    private var activeEditor: AnnotationInputView?

    init(
        frame: CGRect,
        screenshot: NSImage,
        onComplete: @escaping (NSImage) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.screenshot = screenshot
        self.onComplete = onComplete
        self.onCancel = onCancel
        super.init(frame: frame)
        wantsLayer = true
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

        annotations.forEach { annotation in
            drawAnnotation(annotation)
        }

        if let pendingAnnotation {
            drawAnnotation(pendingAnnotation, isDraft: true)
        } else {
            drawLivePreview()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard activeEditor == nil else { return }

        let point = convert(event.locationInWindow, from: nil)
        dragStartPoint = point
        dragCurrentPoint = point

        if toolMode == .freeform {
            freeformPoints = [point]
        }

        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragStartPoint != nil else { return }

        let point = convert(event.locationInWindow, from: nil)
        dragCurrentPoint = point

        if toolMode == .freeform {
            freeformPoints.append(point)
        }

        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let annotationOrCrop = makeResultFromCurrentDrag(
            endingAt: convert(event.locationInWindow, from: nil)
        ) else {
            resetDragState()
            needsDisplay = true
            return
        }

        resetDragState()

        switch annotationOrCrop {
        case let .annotation(annotation):
            pendingAnnotation = annotation
            presentEditor(for: annotation)
        case let .crop(rect):
            guard rect.width > 10, rect.height > 10 else {
                needsDisplay = true
                return
            }
            registerSnapshot()
            cropRect = rect
            selectTool(.arrow)
        }

        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if activeEditor != nil {
            super.keyDown(with: event)
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

        if isReturnKey(event.keyCode) {
            if event.modifierFlags.contains(.shift) {
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

    private func makeResultFromCurrentDrag(endingAt endPoint: CGPoint) -> DragResult? {
        guard let start = dragStartPoint else { return nil }

        switch toolMode {
        case .arrow:
            let annotation = CanvasAnnotation(
                kind: .arrow(start: start, end: endPoint),
                text: "",
                style: annotationStyle
            )
            return annotation.kind.isSubstantial ? .annotation(annotation) : nil
        case .rectangle:
            let rect = rect(from: start, to: endPoint)
            let annotation = CanvasAnnotation(
                kind: .rectangle(rect),
                text: "",
                style: annotationStyle
            )
            return annotation.kind.isSubstantial ? .annotation(annotation) : nil
        case .ellipse:
            let rect = rect(from: start, to: endPoint)
            let annotation = CanvasAnnotation(
                kind: .ellipse(rect),
                text: "",
                style: annotationStyle
            )
            return annotation.kind.isSubstantial ? .annotation(annotation) : nil
        case .freeform:
            var points = freeformPoints
            if points.last != endPoint {
                points.append(endPoint)
            }
            let annotation = CanvasAnnotation(
                kind: .freeform(points),
                text: "",
                style: annotationStyle
            )
            return annotation.kind.isSubstantial ? .annotation(annotation) : nil
        case .crop:
            return .crop(rect(from: start, to: endPoint))
        }
    }

    private func presentEditor(for annotation: CanvasAnnotation) {
        activeEditor?.removeFromSuperview()

        let editor = AnnotationInputView(
            onSubmit: { [weak self] text in
                self?.commitPendingAnnotation(text: text)
            },
            onCancel: { [weak self] in
                self?.discardPendingAnnotation()
            }
        )

        let desiredSize = CGSize(width: 280, height: 84)
        let origin = clampedEditorOrigin(near: annotation.textAnchor, size: desiredSize)
        editor.frame = CGRect(origin: origin, size: desiredSize)

        addSubview(editor)
        activeEditor = editor
        window?.makeFirstResponder(editor.textField)
    }

    private func commitPendingAnnotation(text: String) {
        guard var pendingAnnotation else { return }
        registerSnapshot()
        pendingAnnotation.text = text
        annotations.append(pendingAnnotation)
        self.pendingAnnotation = nil
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

    private func removeEditor() {
        activeEditor?.removeFromSuperview()
        activeEditor = nil
        window?.makeFirstResponder(self)
    }

    private func selectTool(_ mode: ToolMode) {
        toolMode = mode
        resetDragState()
        refreshHUDState()
        needsDisplay = true
    }

    private func clearCanvas() {
        guard !annotations.isEmpty || cropRect != nil else { return }
        registerSnapshot()
        annotations.removeAll()
        cropRect = nil
        pendingAnnotation = nil
        removeEditor()
        refreshHUDState()
        needsDisplay = true
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
        AnnotationSnapshot(annotations: annotations, cropRect: cropRect)
    }

    private func apply(snapshot: AnnotationSnapshot) {
        annotations = snapshot.annotations
        cropRect = snapshot.cropRect
        pendingAnnotation = nil
        removeEditor()
        refreshHUDState()
        needsDisplay = true
    }

    private func refreshHUDState() {
        hudView.setTool(toolMode)
        hudView.setUndoRedoState(canUndo: !undoStack.isEmpty, canRedo: !redoStack.isEmpty)
    }

    private func cancelCapture() {
        pendingAnnotation = nil
        removeEditor()
        onCancel()
    }

    private func drawLivePreview() {
        switch toolMode {
        case .crop:
            if let currentCropRect = resolvedCropRect() {
                drawCropOverlay(rect: currentCropRect, isDraft: dragStartPoint != nil)
            }
        case .freeform:
            if freeformPoints.count > 1 {
                drawFreeform(points: freeformPoints, style: annotationStyle, isDraft: true)
            }
        case .arrow, .rectangle, .ellipse:
            guard let draftAnnotation = draftAnnotationFromDrag() else { return }
            drawAnnotation(draftAnnotation, isDraft: true)
        }
    }

    private func draftAnnotationFromDrag() -> CanvasAnnotation? {
        guard let start = dragStartPoint, let end = dragCurrentPoint else { return nil }

        switch toolMode {
        case .arrow:
            return CanvasAnnotation(kind: .arrow(start: start, end: end), text: "", style: annotationStyle)
        case .rectangle:
            return CanvasAnnotation(kind: .rectangle(rect(from: start, to: end)), text: "", style: annotationStyle)
        case .ellipse:
            return CanvasAnnotation(kind: .ellipse(rect(from: start, to: end)), text: "", style: annotationStyle)
        case .freeform:
            return nil
        case .crop:
            return nil
        }
    }

    private func drawAnnotation(_ annotation: CanvasAnnotation, isDraft: Bool = false) {
        switch annotation.kind {
        case let .arrow(start, end):
            drawArrow(
                from: start,
                to: end,
                text: annotation.text,
                style: annotation.style,
                isDraft: isDraft
            )
        case let .rectangle(rect):
            drawRectangularShape(
                rect: rect,
                text: annotation.text,
                style: annotation.style,
                isDraft: isDraft,
                makePath: { NSBezierPath(rect: $0) }
            )
        case let .ellipse(rect):
            drawRectangularShape(
                rect: rect,
                text: annotation.text,
                style: annotation.style,
                isDraft: isDraft,
                makePath: { NSBezierPath(ovalIn: $0) }
            )
        case let .freeform(points):
            drawFreeform(points: points, style: annotation.style, isDraft: isDraft)
            if !annotation.text.isEmpty {
                drawTextBubble(text: annotation.text, near: annotation.textAnchor, style: annotation.style)
            }
        }
    }

    private func drawArrow(
        from start: CGPoint,
        to end: CGPoint,
        text: String,
        style: AnnotationStyle,
        isDraft: Bool
    ) {
        let shaft = NSBezierPath()
        shaft.move(to: start)
        shaft.line(to: end)
        shaft.lineWidth = isDraft ? 5 : 4
        shaft.lineCapStyle = .round

        style.strokeColor.setStroke()
        shaft.stroke()

        let arrowLength: CGFloat = 16
        let arrowAngle: CGFloat = .pi / 8
        let angle = atan2(end.y - start.y, end.x - start.x)
        let leftPoint = CGPoint(
            x: end.x - arrowLength * cos(angle - arrowAngle),
            y: end.y - arrowLength * sin(angle - arrowAngle)
        )
        let rightPoint = CGPoint(
            x: end.x - arrowLength * cos(angle + arrowAngle),
            y: end.y - arrowLength * sin(angle + arrowAngle)
        )

        let head = NSBezierPath()
        head.move(to: end)
        head.line(to: leftPoint)
        head.move(to: end)
        head.line(to: rightPoint)
        head.lineWidth = 4
        head.lineCapStyle = .round
        style.strokeColor.setStroke()
        head.stroke()

        if !text.isEmpty {
            drawTextBubble(text: text, near: end, style: style)
        }
    }

    private func drawRectangularShape(
        rect: CGRect,
        text: String,
        style: AnnotationStyle,
        isDraft: Bool,
        makePath: (CGRect) -> NSBezierPath
    ) {
        let path = makePath(rect)
        path.lineWidth = isDraft ? 5 : 4
        let dash: [CGFloat] = isDraft ? [8, 5] : []
        if !dash.isEmpty {
            path.setLineDash(dash, count: dash.count, phase: 0)
        }
        style.strokeColor.setStroke()
        path.stroke()

        if !text.isEmpty {
            drawTextBubble(text: text, near: CGPoint(x: rect.maxX, y: rect.maxY), style: style)
        }
    }

    private func drawFreeform(points: [CGPoint], style: AnnotationStyle, isDraft: Bool) {
        guard let first = points.first else { return }

        let path = NSBezierPath()
        path.move(to: first)
        for point in points.dropFirst() {
            path.line(to: point)
        }
        path.lineWidth = isDraft ? 5 : 4
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        style.strokeColor.setStroke()
        path.stroke()
    }

    private func drawTextBubble(text: String, near point: CGPoint, style: AnnotationStyle) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 18, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let rect = textBubbleRect(text: text, near: point)

        let background = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
        NSColor.black.withAlphaComponent(0.76).setFill()
        background.fill()
        attributed.draw(at: CGPoint(x: rect.minX + 12, y: rect.minY + 8))
    }

    private func finishCapture(autoCrop: Bool) {
        pendingAnnotation = nil
        removeEditor()

        let exportImage = rasterizedAnnotatedImage()
        if let exportCropRect = resolvedExportCropRect(autoCrop: autoCrop) {
            onComplete(croppedImage(from: exportImage, cropRect: exportCropRect))
        } else {
            onComplete(exportImage)
        }
    }

    private func resolvedExportCropRect(autoCrop: Bool) -> CGRect? {
        if let cropRect {
            return cropRect
        }

        guard autoCrop else { return nil }
        return autoCropRect()
    }

    private func autoCropRect() -> CGRect? {
        let allBounds = annotations
            .compactMap(annotationBounds(_:))
            .reduce(into: CGRect.null) { partial, rect in
                partial = partial.union(rect)
            }

        guard !allBounds.isNull else { return nil }

        let padding: CGFloat = 28
        let padded = allBounds.insetBy(dx: -padding, dy: -padding)
        return padded.intersection(bounds)
    }

    private func rasterizedAnnotatedImage() -> NSImage {
        let image = NSImage(size: bounds.size)
        image.lockFocus()
        screenshot.draw(in: bounds)
        annotations.forEach { annotation in
            drawAnnotation(annotation)
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

    private func drawBaseOverlay() {
        if cropRect == nil && toolMode != .crop {
            NSColor.black.withAlphaComponent(0.08).setFill()
            bounds.fill()
            return
        }

        if let currentCropRect = resolvedCropRect() {
            let dimmedArea = NSBezierPath(rect: bounds)
            dimmedArea.append(NSBezierPath(rect: currentCropRect))
            dimmedArea.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.34).setFill()
            dimmedArea.fill()
        } else {
            NSColor.black.withAlphaComponent(0.18).setFill()
            bounds.fill()
        }
    }

    private func drawCropOverlay(rect: CGRect, isDraft: Bool) {
        let border = NSBezierPath(rect: rect)
        border.lineWidth = isDraft ? 3 : 2
        let dash: [CGFloat] = [8, 6]
        border.setLineDash(dash, count: dash.count, phase: 0)
        NSColor.white.setStroke()
        border.stroke()
    }

    private func resolvedCropRect() -> CGRect? {
        if toolMode == .crop, let start = dragStartPoint, let end = dragCurrentPoint {
            return rect(from: start, to: end)
        }

        return cropRect
    }

    private func clampedEditorOrigin(near point: CGPoint, size: CGSize) -> CGPoint {
        let padding: CGFloat = 16
        var origin = CGPoint(x: point.x + 12, y: point.y - size.height - 12)
        origin.x = min(max(origin.x, padding), bounds.maxX - size.width - padding)
        origin.y = min(max(origin.y, padding), bounds.maxY - size.height - padding)
        return origin
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
        guard !shapeBounds.isNull else { return nil }

        if annotation.text.isEmpty {
            return shapeBounds
        }

        let bubbleBounds = textBubbleRect(text: annotation.text, near: annotation.textAnchor)
        return shapeBounds.union(bubbleBounds)
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
        }
    }

    private func textBubbleRect(text: String, near point: CGPoint) -> CGRect {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 18, weight: .semibold),
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let textSize = attributed.size()
        let padding = CGSize(width: 12, height: 8)
        var rect = CGRect(
            x: point.x + 12,
            y: point.y + 12,
            width: textSize.width + padding.width * 2,
            height: textSize.height + padding.height * 2
        )

        let safeBounds = bounds.insetBy(dx: 16, dy: 16)
        if rect.maxX > safeBounds.maxX {
            rect.origin.x = max(safeBounds.minX, point.x - rect.width - 12)
        }
        if rect.maxY > safeBounds.maxY {
            rect.origin.y = max(safeBounds.minY, point.y - rect.height - 12)
        }

        return rect
    }

    private func resetDragState() {
        dragStartPoint = nil
        dragCurrentPoint = nil
        freeformPoints.removeAll()
    }

    private func isReturnKey(_ keyCode: UInt16) -> Bool {
        keyCode == UInt16(kVK_Return) || keyCode == 76
    }
}

private enum DragResult {
    case annotation(CanvasAnnotation)
    case crop(CGRect)
}
