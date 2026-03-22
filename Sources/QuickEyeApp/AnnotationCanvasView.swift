import AppKit
import Carbon

final class AnnotationCanvasView: NSView {
    private static let maxExportLongEdge: CGFloat = 1800
    private static let annotationOutlineOuterColor = NSColor.black.withAlphaComponent(0.9)
    private static let annotationOutlineInnerColor = NSColor.white.withAlphaComponent(0.98)
    private static let textBubbleBackgroundColor = NSColor.black.withAlphaComponent(0.84)
    private static let textBubbleBorderColor = NSColor.white.withAlphaComponent(0.18)

    private let screenshot: NSImage
    private let onComplete: (NSImage, AnnotationHistoryPayload?) -> Void
    private let onCancel: (AnnotationHistoryPayload?) -> Void

    private var annotations: [CanvasAnnotation] = []
    private var pendingAnnotation: CanvasAnnotation?
    private var dragStartPoint: CGPoint?
    private var dragCurrentPoint: CGPoint?
    private var freeformPoints: [CGPoint] = []
    private var toolMode: ToolMode = .arrow
    private var annotationStyle: AnnotationStyle = .default
    private var cropRect: CGRect?
    private var selectedAnnotationID: UUID?
    private var movingAnnotationID: UUID?
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
            }
        )
        return view
    }()

    private var activeEditor: AnnotationInputView?

    init(
        frame: CGRect,
        screenshot: NSImage,
        initialState: AnnotationHistoryState? = nil,
        onComplete: @escaping (NSImage, AnnotationHistoryPayload?) -> Void,
        onCancel: @escaping (AnnotationHistoryPayload?) -> Void
    ) {
        self.screenshot = screenshot
        self.onComplete = onComplete
        self.onCancel = onCancel
        super.init(frame: frame)
        wantsLayer = true

        if let initialState {
            annotations = initialState.snapshot.annotations
            cropRect = initialState.snapshot.cropRect
            undoStack = initialState.undoStack
            redoStack = initialState.redoStack
            toolMode = initialState.toolMode
            annotationStyle = initialState.annotationStyle
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

        if let hitAnnotation = annotation(at: point) {
            selectedAnnotationID = hitAnnotation.id
            movingAnnotationID = hitAnnotation.id
            moveStartPoint = point
            moveOriginalAnnotation = hitAnnotation
            hasRecordedMoveSnapshot = false
            needsDisplay = true
            return
        }

        selectedAnnotationID = nil
        dragStartPoint = point
        dragCurrentPoint = point

        if toolMode == .freeform {
            freeformPoints = [point]
        }

        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if let movingAnnotationID, let moveStartPoint, let moveOriginalAnnotation {
            let delta = point - moveStartPoint
            if !hasRecordedMoveSnapshot, abs(delta.width) + abs(delta.height) > 2 {
                registerSnapshot()
                hasRecordedMoveSnapshot = true
            }

            if let index = annotations.firstIndex(where: { $0.id == movingAnnotationID }) {
                annotations[index] = translatedAnnotation(moveOriginalAnnotation, by: delta)
                selectedAnnotationID = movingAnnotationID
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
        if movingAnnotationID != nil {
            movingAnnotationID = nil
            moveStartPoint = nil
            moveOriginalAnnotation = nil
            hasRecordedMoveSnapshot = false
            needsDisplay = true
            return
        }

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

        if isDeleteKey(event.keyCode) {
            deleteSelectedAnnotation()
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
                id: UUID(),
                kind: .arrow(start: start, end: endPoint),
                text: "",
                style: annotationStyle
            )
            return annotation.kind.isSubstantial ? .annotation(annotation) : nil
        case .rectangle:
            let rect = rect(from: start, to: endPoint)
            let annotation = CanvasAnnotation(
                id: UUID(),
                kind: .rectangle(rect),
                text: "",
                style: annotationStyle
            )
            return annotation.kind.isSubstantial ? .annotation(annotation) : nil
        case .ellipse:
            let rect = rect(from: start, to: endPoint)
            let annotation = CanvasAnnotation(
                id: UUID(),
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
                id: UUID(),
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
        selectedAnnotationID = pendingAnnotation.id
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

    private func discardCapture() {
        annotations.removeAll()
        cropRect = nil
        pendingAnnotation = nil
        selectedAnnotationID = nil
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
        AnnotationSnapshot(annotations: annotations, cropRect: cropRect)
    }

    private func apply(snapshot: AnnotationSnapshot) {
        annotations = snapshot.annotations
        cropRect = snapshot.cropRect
        pendingAnnotation = nil
        selectedAnnotationID = nil
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
        onCancel(historyPayloadForPersistence())
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
            return CanvasAnnotation(id: UUID(), kind: .arrow(start: start, end: end), text: "", style: annotationStyle)
        case .rectangle:
            return CanvasAnnotation(id: UUID(), kind: .rectangle(rect(from: start, to: end)), text: "", style: annotationStyle)
        case .ellipse:
            return CanvasAnnotation(id: UUID(), kind: .ellipse(rect(from: start, to: end)), text: "", style: annotationStyle)
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

        if annotation.id == selectedAnnotationID {
            drawSelectionOutline(for: annotation)
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
        shaft.lineCapStyle = .round
        strokeAnnotationPath(shaft, color: style.strokeColor, lineWidth: isDraft ? 5 : 4)

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
        head.lineCapStyle = .round
        strokeAnnotationPath(head, color: style.strokeColor, lineWidth: 4)

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
        let dash: [CGFloat] = isDraft ? [8, 5] : []
        if !dash.isEmpty {
            path.setLineDash(dash, count: dash.count, phase: 0)
        }
        strokeAnnotationPath(path, color: style.strokeColor, lineWidth: isDraft ? 5 : 4)

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
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        strokeAnnotationPath(path, color: style.strokeColor, lineWidth: isDraft ? 5 : 4)
    }

    private func drawTextBubble(text: String, near point: CGPoint, style: AnnotationStyle) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 18, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let rect = textBubbleRect(text: text, near: point)

        let background = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
        Self.textBubbleBackgroundColor.setFill()
        background.fill()
        Self.textBubbleBorderColor.setStroke()
        background.lineWidth = 1
        background.stroke()
        attributed.draw(at: CGPoint(x: rect.minX + 12, y: rect.minY + 8))
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

    private func drawSelectionOutline(for annotation: CanvasAnnotation) {
        guard let bounds = annotationBounds(annotation), !bounds.isNull else { return }

        let outlineRect = bounds.insetBy(dx: -8, dy: -8)
        let path = NSBezierPath(roundedRect: outlineRect, xRadius: 10, yRadius: 10)
        let dash: [CGFloat] = [7, 5]
        path.setLineDash(dash, count: dash.count, phase: 0)
        path.lineWidth = 2
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }

    private func finishCapture(autoCrop: Bool) {
        pendingAnnotation = nil
        removeEditor()

        let exportImage = rasterizedAnnotatedImage()
        let finalizedImage: NSImage
        if let exportCropRect = resolvedExportCropRect(autoCrop: autoCrop) {
            finalizedImage = croppedImage(from: exportImage, cropRect: exportCropRect)
        } else {
            finalizedImage = exportImage
        }

        onComplete(
            downscaledImageIfNeeded(from: finalizedImage),
            historyPayloadForPersistence()
        )
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
            .compactMap(autoCropBounds(_:))
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

    private func autoCropBounds(_ annotation: CanvasAnnotation) -> CGRect? {
        guard var bounds = annotationBounds(annotation) else { return nil }

        if case let .arrow(start, end) = annotation.kind {
            bounds = bounds
                .union(arrowTargetFocusRect(from: start, to: end))
                .union(arrowSourceFocusRect(from: start, to: end))
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

    private func arrowTargetFocusRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        let focusSize = CGSize(width: 180, height: 180)
        let halfSize = CGSize(width: focusSize.width / 2, height: focusSize.height / 2)

        var origin = CGPoint(
            x: end.x - halfSize.width,
            y: end.y - halfSize.height
        )

        let delta = end - start
        let length = max(sqrt((delta.width * delta.width) + (delta.height * delta.height)), 1)
        let unit = CGSize(width: delta.width / length, height: delta.height / length)

        // Bias the focus area slightly in the arrow direction so the target side
        // gets more breathing room than the tail side.
        origin.x += unit.width * 28
        origin.y += unit.height * 28

        let focusRect = CGRect(origin: origin, size: focusSize)
        return focusRect.intersection(bounds)
    }

    private func arrowSourceFocusRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        let focusSize = CGSize(width: 110, height: 110)
        let halfSize = CGSize(width: focusSize.width / 2, height: focusSize.height / 2)

        var origin = CGPoint(
            x: start.x - halfSize.width,
            y: start.y - halfSize.height
        )

        let delta = end - start
        let length = max(sqrt((delta.width * delta.width) + (delta.height * delta.height)), 1)
        let unit = CGSize(width: delta.width / length, height: delta.height / length)

        // Bias the source region slightly opposite the arrow direction so we keep
        // more context around where the gesture started.
        origin.x -= unit.width * 16
        origin.y -= unit.height * 16

        let focusRect = CGRect(origin: origin, size: focusSize)
        return focusRect.intersection(bounds)
    }

    private func resetDragState() {
        dragStartPoint = nil
        dragCurrentPoint = nil
        freeformPoints.removeAll()
        movingAnnotationID = nil
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
        guard let selectedAnnotationID,
              annotations.contains(where: { $0.id == selectedAnnotationID }) else { return }

        registerSnapshot()
        annotations.removeAll { $0.id == selectedAnnotationID }
        self.selectedAnnotationID = nil
        refreshHUDState()
        needsDisplay = true
    }

    private func annotation(at point: CGPoint) -> CanvasAnnotation? {
        for annotation in annotations.reversed() {
            if annotationContainsPoint(annotation, point: point) {
                return annotation
            }
        }
        return nil
    }

    private func annotationContainsPoint(_ annotation: CanvasAnnotation, point: CGPoint) -> Bool {
        if !annotation.text.isEmpty && textBubbleRect(text: annotation.text, near: annotation.textAnchor).contains(point) {
            return true
        }

        switch annotation.kind {
        case let .arrow(start, end):
            return distanceFromPoint(point, toSegmentStart: start, end: end) <= 18
        case let .rectangle(rect):
            return rect.insetBy(dx: -12, dy: -12).contains(point)
        case let .ellipse(rect):
            return rect.insetBy(dx: -12, dy: -12).contains(point)
        case let .freeform(points):
            return points.boundingRect.insetBy(dx: -12, dy: -12).contains(point)
        }
    }

    private func translatedAnnotation(_ annotation: CanvasAnnotation, by delta: CGSize) -> CanvasAnnotation {
        var moved = annotation
        switch annotation.kind {
        case let .arrow(start, end):
            moved.kind = .arrow(start: start + delta, end: end + delta)
        case let .rectangle(rect):
            moved.kind = .rectangle(rect.offsetBy(dx: delta.width, dy: delta.height))
        case let .ellipse(rect):
            moved.kind = .ellipse(rect.offsetBy(dx: delta.width, dy: delta.height))
        case let .freeform(points):
            moved.kind = .freeform(points.map { $0 + delta })
        }
        return moved
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
        guard !annotations.isEmpty || cropRect != nil else { return nil }

        let state = currentSessionState()
        let previewBase = rasterizedAnnotatedImage()
        let previewImage: NSImage
        if let cropRect {
            previewImage = croppedImage(from: previewBase, cropRect: cropRect)
        } else {
            previewImage = previewBase
        }

        return AnnotationHistoryPayload(state: state, previewImage: previewImage)
    }

    private func currentSessionState() -> AnnotationHistoryState {
        AnnotationHistoryState(
            snapshot: currentSnapshot(),
            undoStack: undoStack,
            redoStack: redoStack,
            toolMode: toolMode,
            annotationStyle: annotationStyle
        )
    }
}

private enum DragResult {
    case annotation(CanvasAnnotation)
    case crop(CGRect)
}
