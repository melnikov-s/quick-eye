import AppKit

final class AnnotationWindowController: NSWindowController {
    init(
        capture: ScreenCapture,
        onComplete: @escaping (NSImage) -> Void,
        onCancel: @escaping () -> Void
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
            onComplete: onComplete,
            onCancel: onCancel
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
