import AppKit

final class AnnotationWindowController: NSWindowController {
    init(
        capture: ScreenCapture,
        initialState: AnnotationHistoryState? = nil,
        historyItemID: UUID? = nil,
        onComplete: @escaping (NSImage, CaptureHistoryItem?) -> Void,
        onCancel: @escaping (CaptureHistoryItem?) -> Void
    ) {
        let window = AnnotationWindow(
            contentRect: capture.screenFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.ignoresMouseEvents = false
        window.hasShadow = false

        let contentView = AnnotationCanvasView(
            frame: CGRect(origin: .zero, size: capture.screenFrame.size),
            screenshot: capture.image,
            defaultExportRect: capture.defaultExportRect,
            initialState: initialState,
            onComplete: { image, historyPayload in
                onComplete(
                    image,
                    historyPayload.map {
                        CaptureHistoryItem(
                            id: historyItemID ?? UUID(),
                            capture: capture,
                            state: $0.state,
                            thumbnail: $0.previewImage.quickEyeThumbnailImage,
                            createdAt: Date()
                        )
                    }
                )
            },
            onCancel: { historyPayload in
                onCancel(
                    historyPayload.map {
                        CaptureHistoryItem(
                            id: historyItemID ?? UUID(),
                            capture: capture,
                            state: $0.state,
                            thumbnail: $0.previewImage.quickEyeThumbnailImage,
                            createdAt: Date()
                        )
                    }
                )
            }
        )

        window.contentView = contentView
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        if let contentView = window?.contentView {
            window?.makeFirstResponder(contentView)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

private final class AnnotationWindow: NSWindow {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }
}

private extension NSImage {
    var quickEyeThumbnailImage: NSImage {
        let targetSize = NSSize(width: 164, height: 104)
        let thumbnail = NSImage(size: targetSize)
        thumbnail.lockFocus()

        let aspectRatio = size.width / max(size.height, 1)
        let targetAspectRatio = targetSize.width / targetSize.height
        let drawRect: CGRect

        if aspectRatio > targetAspectRatio {
            let height = targetSize.width / aspectRatio
            drawRect = CGRect(
                x: 0,
                y: (targetSize.height - height) / 2,
                width: targetSize.width,
                height: height
            )
        } else {
            let width = targetSize.height * aspectRatio
            drawRect = CGRect(
                x: (targetSize.width - width) / 2,
                y: 0,
                width: width,
                height: targetSize.height
            )
        }

        draw(in: drawRect)
        thumbnail.unlockFocus()
        return thumbnail
    }
}
