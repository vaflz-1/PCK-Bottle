import AppKit
import CoreServices
import UniformTypeIdentifiers

final class DropTargetView: NSView {
    weak var delegate: DropTargetViewDelegate?
    var title = "Drop .app or .pck here" {
        didSet {
            needsDisplay = true
        }
    }
    private var isHighlighted = false {
        didSet {
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        registerForDraggedTypes([.fileURL])
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
        (isHighlighted ? NSColor.systemBlue.withAlphaComponent(0.16) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        NSColor.systemBlue.withAlphaComponent(isHighlighted ? 0.8 : 0.35).setStroke()
        path.lineWidth = 2
        path.setLineDash([6, 5], count: 2, phase: 0)
        path.stroke()

        drawCenteredDropTitle(
            title,
            in: bounds,
            font: NSFont.systemFont(ofSize: 15, weight: .medium),
            color: .secondaryLabelColor
        )
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        isHighlighted = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isHighlighted = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isHighlighted = false
        let pasteboard = sender.draggingPasteboard
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL], !urls.isEmpty else {
            return false
        }
        delegate?.dropTargetView(self, accepted: urls)
        return true
    }
}

/// The Changes panel's container, also a drop target for external file URLs so
/// users can drag files from Finder into the left pane to add them (a restored
/// regression). Drops are forwarded to the controller, which stages them as
/// ADDs at the package root via the same path the tree uses.
final class ChangesDropContainerView: NSVisualEffectView {
    var onURLsDropped: (([URL]) -> Void)?
    private var isHighlighted = false {
        didSet {
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    private func fileURLs(from sender: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !fileURLs(from: sender).isEmpty else {
            return []
        }
        isHighlighted = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isHighlighted = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isHighlighted = false
        let urls = fileURLs(from: sender).filter { $0.isFileURL }
        guard !urls.isEmpty else {
            return false
        }
        onURLsDropped?(urls)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isHighlighted else {
            return
        }
        let rect = bounds.insetBy(dx: 3, dy: 3)
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        NSColor.systemBlue.withAlphaComponent(0.08).setFill()
        path.fill()
        NSColor.systemBlue.withAlphaComponent(0.7).setStroke()
        path.lineWidth = 2
        path.setLineDash([6, 5], count: 2, phase: 0)
        path.stroke()
    }
}

