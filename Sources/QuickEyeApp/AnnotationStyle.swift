import AppKit

struct AnnotationStyle {
    var strokeColor: NSColor

    static let `default` = AnnotationStyle(
        strokeColor: .systemRed
    )
}

enum ToolMode: CaseIterable {
    case arrow
    case rectangle
    case ellipse
    case freeform
    case crop

    var description: String {
        switch self {
        case .arrow:
            return "Arrow mode: drag to point, then type your note."
        case .rectangle:
            return "Box mode: drag to frame an area, then add a note."
        case .ellipse:
            return "Circle mode: drag to surround a region, then add a note."
        case .freeform:
            return "Freeform mode: draw around the area, then add a note."
        case .crop:
            return "Crop mode: drag a frame around the area you want to keep."
        }
    }
}

struct CanvasAnnotation {
    var kind: AnnotationKind
    var text: String
    var style: AnnotationStyle

    var textAnchor: CGPoint {
        kind.textAnchor
    }
}

enum AnnotationKind {
    case arrow(start: CGPoint, end: CGPoint)
    case rectangle(CGRect)
    case ellipse(CGRect)
    case freeform([CGPoint])

    var textAnchor: CGPoint {
        switch self {
        case let .arrow(_, end):
            return end
        case let .rectangle(rect), let .ellipse(rect):
            return CGPoint(x: rect.maxX, y: rect.maxY)
        case let .freeform(points):
            let bounds = points.boundingRect
            return CGPoint(x: bounds.maxX, y: bounds.maxY)
        }
    }

    var isSubstantial: Bool {
        switch self {
        case let .arrow(start, end):
            return start.distance(to: end) > 10
        case let .rectangle(rect), let .ellipse(rect):
            return rect.width > 10 && rect.height > 10
        case let .freeform(points):
            return points.count > 2 && points.pathLength > 24
        }
    }
}

struct AnnotationSnapshot {
    var annotations: [CanvasAnnotation]
    var cropRect: CGRect?
}

struct AnnotationSessionState {
    var snapshot: AnnotationSnapshot
    var undoStack: [AnnotationSnapshot]
    var redoStack: [AnnotationSnapshot]
    var toolMode: ToolMode
    var annotationStyle: AnnotationStyle
}

typealias AnnotationHistoryState = AnnotationSessionState

struct CaptureHistoryItem {
    let id: UUID
    let capture: ScreenCapture
    let state: AnnotationHistoryState
    let thumbnail: NSImage
    let createdAt: Date
}

struct AnnotationHistoryPayload {
    let state: AnnotationHistoryState
    let previewImage: NSImage
}

struct ColorOption {
    let name: String
    let color: NSColor
}

extension Array where Element == CGPoint {
    var boundingRect: CGRect {
        guard let first else { return .zero }

        return dropFirst().reduce(
            CGRect(origin: first, size: .zero)
        ) { partial, point in
            partial.union(CGRect(origin: point, size: .zero))
        }
    }

    var pathLength: CGFloat {
        guard count > 1 else { return 0 }

        return zip(self, dropFirst()).reduce(0) { total, pair in
            total + pair.0.distance(to: pair.1)
        }
    }
}

extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat {
        hypot(other.x - x, other.y - y)
    }
}

extension NSColor {
    var quickEyeMenuSwatchImage: NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16))
        image.lockFocus()

        let outerRect = CGRect(x: 0.5, y: 0.5, width: 15, height: 15)
        let innerRect = CGRect(x: 2.5, y: 2.5, width: 11, height: 11)

        let outerPath = NSBezierPath(ovalIn: outerRect)
        NSColor.separatorColor.setStroke()
        outerPath.lineWidth = 1
        outerPath.stroke()

        let innerPath = NSBezierPath(ovalIn: innerRect)
        self.setFill()
        innerPath.fill()

        image.unlockFocus()
        return image
    }
}
