import AppKit
import CoreServices
import UniformTypeIdentifiers

final class PackageOutlineView: NSOutlineView {
    var onDelete: (() -> Void)?
    var onDuplicate: (() -> Void)?
    var onCopy: (() -> Void)?
    var onPaste: (() -> Void)?
    var onExtract: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // ⌘Z / ⌘⇧Z are handled by the Edit menu → EditorWindowController.undo:.
        // These tree shortcuts act on the selection, so require focus.
        guard window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        if modifiers.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "d":
                onDuplicate?()
                return true
            case "c":
                onCopy?()
                return true
            case "v":
                onPaste?()
                return true
            case "e":
                onExtract?()
                return true
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // ⌘⌫ = delete the selection.
        if modifiers.contains(.command), let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first,
           scalar == UnicodeScalar(NSDeleteCharacter)! || scalar == UnicodeScalar(NSBackspaceCharacter)! {
            onDelete?()
            return
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        // Select the clicked row only if it is outside the current selection,
        // and never scroll it into view (avoids the right-click jump/jiggle).
        if row >= 0, !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return super.menu(for: event)
    }
}

final class PackageContentsViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, NSMenuItemValidation, NSFilePromiseProviderDelegate {
    weak var changesPanel: ChangesViewController?
    let package: PackageCandidate
    lazy var outlineView = PackageOutlineView()
    let titleLabel = NSTextField(labelWithString: "")
    let statusLabel = NSTextField(labelWithString: "")
    let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
    let sizeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
    let rootNode = PackageTreeNode(name: "Package root", path: "", isDirectory: true)
    var existingPackagePaths = Set<String>()
    /// Immutable snapshot of the package as last loaded from disk.
    var loadedEntries: [PckEntryPayload] = []
    /// Ordered staged operations. The displayed tree is the projection of
    /// `loadedEntries` through these ops; nothing is written until Pack.
    var stagedOperations: [StagedOperationRecord] = []
    var isPacking = false
    var pendingStatusMessage: String?
    var preservedEditorWindowFrame: NSRect?
    var loadedItemCount = 0
    /// Serial queue used to fulfil file-promise drag-out extractions.
    lazy var promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    /// Maps an in-flight file-promise provider to the package path it extracts.
    var promisePaths: [ObjectIdentifier: String] = [:]

    init(package: PackageCandidate) {
        self.package = package
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView()
        titleLabel.stringValue = package.displayName
        titleLabel.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        // Without low compression resistance a long title/status (e.g. the full
        // PCK path in the pack-result message) forces the header — and the whole
        // window — to grow to its intrinsic width. Let the labels truncate.
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        statusLabel.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.maximumNumberOfLines = 1
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let titleStack = NSStackView(views: [titleLabel, statusLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 6
        titleStack.translatesAutoresizingMaskIntoConstraints = false

        let headerStack = NSStackView(views: [titleStack])
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.spacing = 12
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        nameColumn.width = 460

        sizeColumn.width = 110

        outlineView.addTableColumn(nameColumn)
        outlineView.addTableColumn(sizeColumn)
        outlineView.outlineTableColumn = nameColumn
        outlineView.delegate = self
        outlineView.dataSource = self
        outlineView.headerView = NSTableHeaderView()
        outlineView.rowHeight = 28
        outlineView.allowsMultipleSelection = true
        // The tree is the single drop target for external files/folders.
        outlineView.registerForDraggedTypes([.pckBottleSourceItems, .pckBottleSourceItem, .fileURL])
        // Drag a row OUT to Finder → extract (copy) via file promises.
        outlineView.setDraggingSourceOperationMask(.copy, forLocal: false)
        // Right-click extraction menu (operates on clicked row + selection).
        outlineView.menu = makeOutlineMenu()
        // Keyboard shortcuts on the tree itself.
        outlineView.onDelete = { [weak self] in self?.deleteSelectedItems() }
        outlineView.onDuplicate = { [weak self] in self?.duplicateSelectedItems() }
        outlineView.onCopy = { [weak self] in self?.copySelectedItems() }
        outlineView.onPaste = { [weak self] in self?.pasteFromClipboard() }
        outlineView.onExtract = { [weak self] in self?.extractSelectedItemsViaPanel() }

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.documentView = outlineView
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(headerStack)
        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            headerStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            headerStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            headerStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 16),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        view = container
    }

    func makeOutlineMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        let extractItem = NSMenuItem(title: localized("menuExtract"), action: #selector(extractClickedItems), keyEquivalent: "e")
        extractItem.keyEquivalentModifierMask = [.command]
        extractItem.target = self
        menu.addItem(extractItem)

        let moveItem = NSMenuItem(title: localized("menuMove"), action: #selector(moveClickedItems), keyEquivalent: "")
        moveItem.target = self
        menu.addItem(moveItem)

        let copyItem = NSMenuItem(title: localized("menuCopy"), action: #selector(copyClickedItems), keyEquivalent: "c")
        copyItem.keyEquivalentModifierMask = [.command]
        copyItem.target = self
        menu.addItem(copyItem)

        let pasteItem = NSMenuItem(title: localized("menuPaste"), action: #selector(pasteFromClipboard), keyEquivalent: "v")
        pasteItem.keyEquivalentModifierMask = [.command]
        pasteItem.target = self
        menu.addItem(pasteItem)

        let duplicateItem = NSMenuItem(title: localized("menuDuplicate"), action: #selector(duplicateClickedItems), keyEquivalent: "d")
        duplicateItem.keyEquivalentModifierMask = [.command]
        duplicateItem.target = self
        menu.addItem(duplicateItem)

        menu.addItem(NSMenuItem.separator())

        let deleteItem = NSMenuItem(title: localized("menuDelete"), action: #selector(deleteClickedItems), keyEquivalent: "\u{8}")
        deleteItem.keyEquivalentModifierMask = [.command]
        deleteItem.target = self
        menu.addItem(deleteItem)

        return menu
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applyLocalization),
            name: .pckBottleLanguageDidChange,
            object: nil
        )
        applyLocalization()
        loadPackageContents()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func selectAll(_ sender: Any?) {
        outlineView.selectAll(sender)
    }

    func loadPackageContents() {
        statusLabel.stringValue = localized("readingPackage")
        let packageURL = package.url

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = PckCoreClient.listPackage(at: packageURL)
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let listing):
                    self.loadedItemCount = listing.entries.count
                    self.loadedEntries = listing.entries
                    self.existingPackagePaths = Set(listing.entries.map { $0.path })
                    self.rebuildProjection()
                    let rootNode = self.rootNode
                    self.outlineView.expandItem(rootNode, expandChildren: false)
                    if let pendingStatusMessage = self.pendingStatusMessage {
                        self.statusLabel.stringValue = pendingStatusMessage
                        self.pendingStatusMessage = nil
                    } else {
                        self.statusLabel.stringValue = self.packageStatus(itemCount: listing.entries.count)
                    }
                case .failure(let error):
                    self.loadedItemCount = 0
                    self.loadedEntries = []
                    self.rootNode.children = []
                    self.outlineView.reloadData()
                    self.statusLabel.stringValue = error.message
                }
                self.restorePreservedEditorWindowFrame()
            }
        }
    }

}
