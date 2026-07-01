import AppKit
import CoreServices
import UniformTypeIdentifiers

final class EditorWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    var onClose: (() -> Void)?
    /// The editor window vends this so ⌘Z / ⌘⇧Z (routed via the Edit menu's
    /// undo:/redo: through the responder chain) reach the staging undo stack.
    private let editorUndoManager = UndoManager()

    init(package: PackageCandidate) {
        let viewController = EditorViewController(package: package)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1320, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = package.displayName
        window.contentMinSize = NSSize(width: 1120, height: 620)
        window.center()
        window.contentViewController = viewController

        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        return editorUndoManager
    }

    // Concrete undo:/redo: in the responder chain so the Edit menu's items work
    // for BOTH click and ⌘Z / ⌘⇧Z keyboard dispatch (relying on the implicit
    // NSWindow routing proved unreliable from the tree).
    @objc func undo(_ sender: Any?) {
        if editorUndoManager.canUndo {
            editorUndoManager.undo()
        }
    }

    @objc func redo(_ sender: Any?) {
        if editorUndoManager.canRedo {
            editorUndoManager.redo()
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undo(_:)):
            return editorUndoManager.canUndo
        case #selector(redo(_:)):
            return editorUndoManager.canRedo
        default:
            return true
        }
    }
}

final class EditorViewController: NSSplitViewController {
    private let package: PackageCandidate

    init(package: PackageCandidate) {
        self.package = package
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let changes = ChangesViewController()
        let packageContents = PackageContentsViewController(package: package)
        // The Changes panel and the package tree drive each other: dropping onto
        // the tree stages operations the Changes panel renders, and the panel's
        // Pack button / per-row removal mutate state the tree owns.
        packageContents.changesPanel = changes
        changes.controller = packageContents

        // Layout: [PCK tree (LEFT, hero, flexible) | Changes (RIGHT, bounded)].
        let contentsItem = NSSplitViewItem(viewController: packageContents)
        contentsItem.minimumThickness = 620
        contentsItem.holdingPriority = .defaultLow

        let changesItem = NSSplitViewItem(viewController: changes)
        changesItem.minimumThickness = 320
        changesItem.maximumThickness = 460
        changesItem.holdingPriority = .defaultHigh
        changesItem.canCollapse = false

        addSplitViewItem(contentsItem)
        addSplitViewItem(changesItem)
    }
}

/// A small rounded capsule label with a semantic background, used for the
/// REPLACE / ADD badges in the Changes panel.
/// One row in the Changes outline: either a collapsible kind GROUP header
/// (Replace/Add/Delete/Duplicate) or a single staged OPERATION beneath it.
