import AppKit
import Carbon

final class AnnotationCanvasView: NSView {
    private let screenshot: NSImage
    private let onComplete: (NSImage) -> Void
    private let onCancel: () -> Void

    private var annotations: [ArrowAnnotation] = []
    private var dragStartPoint: CGPoint?
    private var dragCurrentPoint: CGPoint?

    private lazy var hudView: CaptureHUDView = {
        let view = CaptureHUDView(
            onDone: { [weak self] in
                self?.finishCapture()
            },
            onCancel: { [weak self] in
                self?.cancelCapture()
            },
            onClear: { [weak self] in
                self?.annotations.removeAll()
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
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        screenshot.draw(in: bounds)
        NSColor.black.withAlphaComponent(0.08).setFill()
        bounds.fill()
        annotations.forEach(drawAnnotation(_:))

        if let dragStartPoint, let dragCurrentPoint {
            drawArrow(
                from: dragStartPoint,
                to: dragCurrentPoint,
                text: nil,
                isDraft: true
            )
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard activeEditor == nil else { return }

        let point = convert(event.locationInWindow, from: nil)
        dragStartPoint = point
        dragCurrentPoint = point
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragStartPoint != nil else { return }

        let point = convert(event.locationInWindow, from: nil)
        dragCurrentPoint = point
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = dragStartPoint else { return }
        let end = convert(event.locationInWindow, from: nil)
        dragStartPoint = nil
        dragCurrentPoint = nil
        guard start.distance(to: end) > 10 else {
            needsDisplay = true
            return
        }
        presentEditor(forStart: start, end: end)
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            cancelCapture()
            return
        }

        super.keyDown(with: event)
    }

    private func presentEditor(forStart start: CGPoint, end: CGPoint) {
        activeEditor?.removeFromSuperview()

        let editor = AnnotationInputView(
            onSubmit: { [weak self] text in
                guard let self else { return }
                self.annotations.append(
                    ArrowAnnotation(start: start, end: end, text: text)
                )
                self.removeEditor()
                self.needsDisplay = true
            },
            onCancel: { [weak self] in
                self?.removeEditor()
                self?.needsDisplay = true
            }
        )

        let desiredSize = CGSize(width: 280, height: 84)
        let origin = clampedEditorOrigin(near: end, size: desiredSize)
        editor.frame = CGRect(origin: origin, size: desiredSize)

        addSubview(editor)
        activeEditor = editor
        window?.makeFirstResponder(editor.textField)
    }

    private func removeEditor() {
        activeEditor?.removeFromSuperview()
        activeEditor = nil
        window?.makeFirstResponder(self)
    }

    private func cancelCapture() {
        removeEditor()
        onCancel()
    }

    private func drawArrow(
        from start: CGPoint,
        to end: CGPoint,
        text: String?,
        isDraft: Bool
    ) {
        let shaft = NSBezierPath()
        shaft.move(to: start)
        shaft.line(to: end)
        shaft.lineWidth = isDraft ? 5 : 4
        shaft.lineCapStyle = .round

        NSColor.systemRed.setStroke()
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
        NSColor.systemRed.setStroke()
        head.stroke()

        guard let text, !text.isEmpty else { return }
        drawTextBubble(text: text, near: end)
    }

    private func drawAnnotation(_ annotation: ArrowAnnotation) {
        drawArrow(from: annotation.start, to: annotation.end, text: annotation.text, isDraft: false)
    }

    private func drawTextBubble(text: String, near point: CGPoint) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 18, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let textSize = attributed.size()
        let padding = CGSize(width: 12, height: 8)
        let rect = CGRect(
            x: point.x + 12,
            y: point.y + 12,
            width: textSize.width + padding.width * 2,
            height: textSize.height + padding.height * 2
        )

        let background = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
        NSColor.black.withAlphaComponent(0.76).setFill()
        background.fill()
        attributed.draw(at: CGPoint(x: rect.minX + padding.width, y: rect.minY + padding.height))
    }

    private func finishCapture() {
        removeEditor()
        let exportImage = rasterizedAnnotatedImage()
        onComplete(exportImage)
    }

    private func rasterizedAnnotatedImage() -> NSImage {
        let image = NSImage(size: bounds.size)
        image.lockFocus()
        screenshot.draw(in: bounds)
        annotations.forEach(drawAnnotation(_:))
        image.unlockFocus()
        return image
    }

    private func clampedEditorOrigin(near point: CGPoint, size: CGSize) -> CGPoint {
        let padding: CGFloat = 16
        var origin = CGPoint(x: point.x + 12, y: point.y - size.height - 12)
        origin.x = min(max(origin.x, padding), bounds.maxX - size.width - padding)
        origin.y = min(max(origin.y, padding), bounds.maxY - size.height - padding)
        return origin
    }
}

private struct ArrowAnnotation {
    let start: CGPoint
    let end: CGPoint
    let text: String
}

private extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat {
        hypot(other.x - x, other.y - y)
    }
}
