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
    private let package: PackageCandidate
    private lazy var outlineView = PackageOutlineView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
    private let sizeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
    private let rootNode = PackageTreeNode(name: "Package root", path: "", isDirectory: true)
    private var existingPackagePaths = Set<String>()
    /// Immutable snapshot of the package as last loaded from disk.
    private var loadedEntries: [PckEntryPayload] = []
    /// Ordered staged operations. The displayed tree is the projection of
    /// `loadedEntries` through these ops; nothing is written until Pack.
    private var stagedOperations: [StagedOperationRecord] = []
    private(set) var isPacking = false
    private var pendingStatusMessage: String?
    private var preservedEditorWindowFrame: NSRect?
    private var loadedItemCount = 0
    /// Serial queue used to fulfil file-promise drag-out extractions.
    private lazy var promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    /// Maps an in-flight file-promise provider to the package path it extracts.
    private var promisePaths: [ObjectIdentifier: String] = [:]

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

    private func makeOutlineMenu() -> NSMenu {
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

    // MARK: - Optimistic projection

    /// Recompute the displayed tree as the projection of `loadedEntries` through
    /// the staged `stagedOperations`. No disk writes happen here.
    ///
    /// When `animated` is true and only leaf rows changed under unchanged folders
    /// (the common case: a staged add, delete, duplicate, paste, or an undo of
    /// any of those), the rows slide in/out individually for a Finder-like feel.
    /// Anything structural (a folder appearing or disappearing) falls back to a
    /// plain reload, which is always correct.
    private func rebuildProjection(animated: Bool = false) {
        let target = Self.buildProjectedTree(entries: loadedEntries, operations: stagedOperations)

        guard animated, isViewLoaded, !rootNode.children.isEmpty else {
            rootNode.children = target
            outlineView.reloadData()
            return
        }

        // Diff the live tree against the target by file path. Animate only when
        // the set of directories is identical — then every added/removed leaf has
        // a parent that already exists, so in-place insert/remove is safe.
        let oldFiles = Self.collectFilePaths(rootNode.children)
        let newFiles = Self.collectFilePaths(target)
        guard Self.collectDirPaths(rootNode.children) == Self.collectDirPaths(target) else {
            rootNode.children = target
            outlineView.reloadData()
            return
        }

        let removed = oldFiles.subtracting(newFiles)
        let added = newFiles.subtracting(oldFiles)
        let attributes = Self.attributeMap(for: target)

        if !removed.isEmpty || !added.isEmpty {
            // Index the live directory nodes so insertions find their parent.
            var dirByPath: [String: PackageTreeNode] = ["": rootNode]
            func indexDirs(_ node: PackageTreeNode) {
                for child in node.children where child.isDirectory {
                    dirByPath[child.path] = child
                    indexDirs(child)
                }
            }
            indexDirs(rootNode)

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                outlineView.beginUpdates()

                // Removals first, grouped by parent, bottom-up so indices stay valid.
                var removalsByParent: [ObjectIdentifier: (parent: PackageTreeNode, indexes: IndexSet)] = [:]
                func collectRemovals(_ node: PackageTreeNode) {
                    for (index, child) in node.children.enumerated() {
                        if !child.isDirectory && removed.contains(child.path) {
                            let key = ObjectIdentifier(node)
                            var entry = removalsByParent[key] ?? (node, IndexSet())
                            entry.indexes.insert(index)
                            removalsByParent[key] = entry
                        }
                        collectRemovals(child)
                    }
                }
                collectRemovals(rootNode)
                for (_, entry) in removalsByParent {
                    for index in entry.indexes.sorted(by: >) {
                        entry.parent.children.remove(at: index)
                    }
                    outlineView.removeItems(at: entry.indexes, inParent: entry.parent, withAnimation: [.effectFade, .slideUp])
                }

                // Insertions, in sorted order, into the matching live parent.
                for path in added.sorted() {
                    let directory = (path as NSString).deletingLastPathComponent
                    guard let parent = dirByPath[directory] else {
                        continue
                    }
                    let leaf = PackageTreeNode(
                        name: (path as NSString).lastPathComponent,
                        path: path,
                        isDirectory: false,
                        size: attributes[path]?.size ?? 0
                    )
                    leaf.tint = attributes[path]?.tint ?? .none
                    let index = Self.fileInsertionIndex(for: leaf, in: parent)
                    parent.children.insert(leaf, at: index)
                    outlineView.insertItems(at: IndexSet(integer: index), inParent: parent, withAnimation: [.effectFade, .slideDown])
                }

                outlineView.endUpdates()
            }
        }

        // Refresh tints/sizes on surviving rows (e.g. undoing a replace clears its
        // yellow tint though the path stays). Reload only the rows that changed.
        applyAttributes(attributes)
    }

    /// Set each live node's tint/size from the target attribute map, reloading
    /// only the rows whose tint actually changed (no structural animation).
    private func applyAttributes(_ attributes: [String: (size: UInt64, tint: PendingTint)]) {
        var changed: [PackageTreeNode] = []
        func walk(_ node: PackageTreeNode) {
            for child in node.children {
                if !child.isDirectory {
                    let newTint = attributes[child.path]?.tint ?? .none
                    if child.tint != newTint {
                        child.tint = newTint
                        changed.append(child)
                    }
                    if let size = attributes[child.path]?.size {
                        child.size = size
                    }
                }
                walk(child)
            }
        }
        walk(rootNode)
        for node in changed {
            outlineView.reloadItem(node)
        }
    }

    /// Collect the paths of every file (non-directory) leaf in a node forest.
    private static func collectFilePaths(_ nodes: [PackageTreeNode]) -> Set<String> {
        var paths = Set<String>()
        for node in nodes {
            if node.isDirectory {
                paths.formUnion(collectFilePaths(node.children))
            } else {
                paths.insert(node.path)
            }
        }
        return paths
    }

    /// Collect the paths of every directory in a node forest.
    private static func collectDirPaths(_ nodes: [PackageTreeNode]) -> Set<String> {
        var paths = Set<String>()
        for node in nodes where node.isDirectory {
            paths.insert(node.path)
            paths.formUnion(collectDirPaths(node.children))
        }
        return paths
    }

    /// path -> (size, tint) for every file leaf in the target tree.
    private static func attributeMap(for nodes: [PackageTreeNode]) -> [String: (size: UInt64, tint: PendingTint)] {
        var map: [String: (size: UInt64, tint: PendingTint)] = [:]
        func walk(_ list: [PackageTreeNode]) {
            for node in list {
                if node.isDirectory {
                    walk(node.children)
                } else {
                    map[node.path] = (node.size, node.tint)
                }
            }
        }
        walk(nodes)
        return map
    }

    /// Where a file leaf belongs among a parent's children: after all directories
    /// (which sort first), in localized-standard name order — matching `sortTree`.
    private static func fileInsertionIndex(for leaf: PackageTreeNode, in parent: PackageTreeNode) -> Int {
        for (index, child) in parent.children.enumerated() where !child.isDirectory {
            if leaf.name.localizedStandardCompare(child.name) == .orderedAscending {
                return index
            }
        }
        return parent.children.count
    }

    /// Build the projected node tree. Start from the loaded entries; then apply
    /// each pending op in order: delete removes a path; add/replace ensures a
    /// node at the target (tinted green for new, yellow when overwriting);
    /// duplicate/copy clones the source entry to the target.
    private static func buildProjectedTree(
        entries: [PckEntryPayload],
        operations: [StagedOperationRecord]
    ) -> [PackageTreeNode] {
        // path -> (size, tint). Order is rebuilt deterministically by buildTree.
        var existing = Set(entries.map { $0.path })
        var sizes: [String: UInt64] = [:]
        for entry in entries where entry.kind != "directory" {
            sizes[entry.path] = entry.size
        }
        var tints: [String: PendingTint] = [:]
        var deleted = Set<String>()

        for op in operations {
            switch op.action {
            case .delete:
                deleted.insert(op.target)
            case .addNew:
                deleted.remove(op.target)
                tints[op.target] = .added
                sizes[op.target] = op.size
                existing.insert(op.target)
            case .replaceExisting:
                deleted.remove(op.target)
                tints[op.target] = .replaced
                sizes[op.target] = op.size
                existing.insert(op.target)
            case .duplicate:
                deleted.remove(op.target)
                tints[op.target] = .duplicate
                sizes[op.target] = op.size
                existing.insert(op.target)
            }
        }

        let visiblePaths = existing.subtracting(deleted)
        let projectedEntries: [PckEntryPayload] = entries
            .filter { visiblePaths.contains($0.path) }
            .map { entry in
                PckEntryPayload(
                    name: entry.name,
                    path: entry.path,
                    absolutePath: entry.absolutePath,
                    size: sizes[entry.path] ?? entry.size,
                    kind: entry.kind
                )
            }
        // Staged-in paths that did not exist in the package.
        let knownPaths = Set(entries.map { $0.path })
        let addedEntries: [PckEntryPayload] = visiblePaths
            .subtracting(knownPaths)
            .sorted()
            .map { path in
                PckEntryPayload(
                    name: (path as NSString).lastPathComponent,
                    path: path,
                    absolutePath: "",
                    size: sizes[path] ?? 0,
                    kind: "file"
                )
            }

        let children = buildTree(from: projectedEntries + addedEntries)
        applyTints(to: children, tints: tints)
        return children
    }

    /// Tint a projected node when its full path matches a pending op target.
    private static func applyTints(to nodes: [PackageTreeNode], tints: [String: PendingTint]) {
        for node in nodes {
            node.tint = tints[node.path] ?? .none
            applyTints(to: node.children, tints: tints)
        }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        return item == nil ? 1 : (item as? PackageTreeNode)?.children.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return rootNode
        }
        let node = item as? PackageTreeNode ?? rootNode
        guard index >= 0, index < node.children.count else {
            // The data source and view briefly disagreed during a reload; return a
            // safe placeholder rather than crashing.
            return PackageTreeNode(name: "", path: "", isDirectory: false)
        }
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? PackageTreeNode else {
            return false
        }
        return node.isDirectory && !node.children.isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? PackageTreeNode else {
            return nil
        }

        let identifier = tableColumn?.identifier ?? NSUserInterfaceItemIdentifier("name")
        let text = identifier.rawValue == "size" ? node.sizeText : packageNodeTitle(for: node)
        if identifier.rawValue == "name" {
            return iconTextCell(tableView: outlineView, identifier: identifier, text: text, node: node)
        }
        return textCell(tableView: outlineView, identifier: identifier, text: text)
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        guard !readStagedItems(from: info).isEmpty else {
            return []
        }
        // Highlight the folder node that will receive the drop. A drop over a
        // file or over empty space retargets to the enclosing directory / root
        // so the user always sees WHERE the files will land.
        let node = item as? PackageTreeNode
        if let node = node, node.isDirectory {
            outlineView.setDropItem(node === rootNode ? nil : node, dropChildIndex: NSOutlineViewDropOnItemIndex)
        } else if let node = node, let parent = parentNode(of: node) {
            outlineView.setDropItem(parent === rootNode ? nil : parent, dropChildIndex: NSOutlineViewDropOnItemIndex)
        } else {
            outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
        }
        return .copy
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        acceptDrop info: NSDraggingInfo,
        item: Any?,
        childIndex index: Int
    ) -> Bool {
        let items = readStagedItems(from: info)
        guard !items.isEmpty else {
            return false
        }

        stage(items: items, under: item as? PackageTreeNode)
        return true
    }

    // MARK: - Drag OUT to Finder (file promises)

    /// A file row dragged into Finder becomes a file promise that, when dropped,
    /// extracts that single package path into the destination. Directory rows
    /// fall back to the right-click "Extract to…" menu (no folder promise).
    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? PackageTreeNode,
              node !== rootNode,
              !node.isDirectory,
              !node.path.isEmpty else {
            return nil
        }

        let typeIdentifier = utiIdentifier(forExtension: (node.name as NSString).pathExtension)

        let provider = NSFilePromiseProvider(fileType: typeIdentifier, delegate: self)
        provider.userInfo = node.path
        promisePaths[ObjectIdentifier(provider)] = node.path
        return provider
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        fileNameForType fileType: String
    ) -> String {
        let path = (filePromiseProvider.userInfo as? String)
            ?? promisePaths[ObjectIdentifier(filePromiseProvider)]
            ?? "file"
        return (path as NSString).lastPathComponent
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        return promiseQueue
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let path = (filePromiseProvider.userInfo as? String)
            ?? promisePaths[ObjectIdentifier(filePromiseProvider)] else {
            completionHandler(PckBottleError(message: "Missing package path for drag."))
            return
        }
        let packageURL = package.url
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PCKBottle", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            completionHandler(error)
            return
        }

        let result = PckCoreClient.extractPaths(
            packageURL: packageURL,
            destinationURL: tempDir,
            paths: [path]
        )
        switch result {
        case .success:
            // Find the single extracted file and copy it to the promised URL.
            let extracted = collectFileURLs(in: tempDir)
            guard let source = extracted.first else {
                completionHandler(PckBottleError(message: "Extraction produced no file."))
                return
            }
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                try FileManager.default.copyItem(at: source, to: url)
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        case .failure(let error):
            completionHandler(PckBottleError(message: error.message))
        }
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func parentNode(of target: PackageTreeNode, in node: PackageTreeNode? = nil) -> PackageTreeNode? {
        let current = node ?? rootNode
        for child in current.children {
            if child === target {
                return current
            }
            if let found = parentNode(of: target, in: child) {
                return found
            }
        }
        return nil
    }

    // MARK: - Keyboard shortcut entry points (operate on current selection)

    private func deleteSelectedItems() { deleteClickedItems() }
    private func duplicateSelectedItems() { duplicateClickedItems() }
    private func copySelectedItems() { copyClickedItems() }
    private func extractSelectedItemsViaPanel() { extractClickedItems() }

    // MARK: - Extraction (right-click "Extract to…")

    @objc private func extractClickedItems() {
        let paths = clickedExtractionPaths()
        guard !paths.isEmpty else {
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.title = localized("extractTo")
        panel.prompt = localized("extractTo")
        guard panel.runModal() == .OK, let destinationURL = panel.url else {
            return
        }

        extractSelectedPackageItems(paths: paths, destinationURL: destinationURL)
    }

    /// Resolve the package nodes targeted by a right-click: the clicked row
    /// combined with the current multi-selection.
    private func clickedNodes() -> [PackageTreeNode] {
        var rows = Set(outlineView.selectedRowIndexes)
        let clicked = outlineView.clickedRow
        if clicked >= 0 {
            rows.insert(clicked)
        }

        var nodes: [PackageTreeNode] = []
        var seen = Set<ObjectIdentifier>()
        for row in rows.sorted() {
            guard let node = outlineView.item(atRow: row) as? PackageTreeNode else {
                continue
            }
            if seen.insert(ObjectIdentifier(node)).inserted {
                nodes.append(node)
            }
        }
        return nodes
    }

    /// Resolve the paths to extract from the right-clicked row combined with the
    /// current multi-selection.
    private func clickedExtractionPaths() -> [String] {
        var paths = Set<String>()
        for node in clickedNodes() {
            paths.formUnion(packageExportPaths(for: node))
        }
        return paths.sorted()
    }

    /// Validate context-menu items: disable everything when nothing is targeted,
    /// and disable Duplicate when no concrete file is selected.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        // Restore is a File-menu command routed through the responder chain; it is
        // available whenever a .bak exists next to this editor's package.
        if menuItem.action == #selector(restoreBackupFromMenu(_:)) {
            return latestBackupURL() != nil
        }
        // Paste depends on the clipboard, not on the tree selection, so allow it
        // whenever the clipboard holds file URLs (it pastes into root by default).
        if menuItem.action == #selector(pasteFromClipboard) {
            return clipboardHasFileURLs()
        }
        let nodes = clickedNodes()
        if nodes.isEmpty {
            return false
        }
        if menuItem.action == #selector(duplicateClickedItems) {
            return nodes.contains { !$0.isDirectory && $0 !== rootNode && !$0.path.isEmpty }
        }
        return true
    }

    private func clipboardHasFileURLs() -> Bool {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: options)
    }

    /// Paste: stage any file/folder URLs on the system clipboard, into the
    /// selected/clicked folder when one is targeted, otherwise package root.
    /// Unlike a drag (which replaces a matching path), paste keeps BOTH copies:
    /// a name collision is renamed "<name> copy" — the classic Finder behaviour —
    /// so a ⌘C/⌘V round-trip never silently overwrites the original.
    @objc private func pasteFromClipboard() {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = (NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? [])
            .filter { $0.isFileURL }
        let items = urls.flatMap(Self.expandExternalSourceURL)
        guard !items.isEmpty else {
            statusLabel.stringValue = localized("pasteEmpty")
            return
        }
        let targetDir = clickedNodes().first { $0.isDirectory && $0 !== rootNode }

        var usedTargets = Set(stagedOperations.map { $0.target })
        let effectivePaths = unwrapWrapperPrefixes(items.map { $0.relativePath })
        let records: [StagedOperationRecord] = zip(items, effectivePaths).map { item, relativePath in
            var target = stageTarget(relativePath: relativePath, under: targetDir, itemCount: items.count)
            if existingPackagePaths.contains(target) || usedTargets.contains(target) {
                target = uniqueDuplicateTarget(for: target, additionalTaken: usedTargets)
            }
            usedTargets.insert(target)
            // Pasted targets are unique by construction, so they are always adds.
            return StagedOperationRecord(
                file: item.file,
                target: target,
                action: .addNew,
                size: item.size,
                sourceName: URL(fileURLWithPath: item.file).lastPathComponent
            )
        }

        mutateStagedOperations(actionName: localized("undoPaste"), animated: true) {
            stagedOperations.append(contentsOf: records)
        }
        statusLabel.stringValue = localized("pasteStaged", records.count)
    }

    // MARK: - Move / Copy / Duplicate / Delete (right-click)

    /// Move to…: extract the selected entries to a chosen folder AND stage a
    /// delete for each so they are removed from the package on Pack.
    @objc private func moveClickedItems() {
        let paths = clickedExtractionPaths()
        guard !paths.isEmpty else {
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.title = localized("menuMove")
        panel.message = localized("moveRemovesFromPackage")
        panel.prompt = localized("menuMove")
        guard panel.runModal() == .OK, let destinationURL = panel.url else {
            return
        }

        let packageURL = package.url
        statusLabel.stringValue = localized("extractingPck", paths.count)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = PckCoreClient.extractPaths(
                packageURL: packageURL,
                destinationURL: destinationURL,
                paths: paths
            )
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let listing):
                    self.stageDeletes(for: paths)
                    self.statusLabel.stringValue = localized(
                        "moveComplete",
                        listing.entries.count,
                        destinationURL.lastPathComponent
                    )
                case .failure(let error):
                    self.statusLabel.stringValue = error.message
                }
            }
        }
    }

    /// Copy: extract the selected entries to a unique temp directory and put the
    /// resulting file URLs on the system pasteboard for pasting in Finder.
    @objc private func copyClickedItems() {
        let paths = clickedExtractionPaths()
        guard !paths.isEmpty else {
            return
        }

        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PCKBottle", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        } catch {
            statusLabel.stringValue = error.localizedDescription
            return
        }

        let packageURL = package.url
        statusLabel.stringValue = localized("extractingPck", paths.count)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = PckCoreClient.extractPaths(
                packageURL: packageURL,
                destinationURL: destinationURL,
                paths: paths
            )
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let listing):
                    let urls = self.collectFileURLs(in: destinationURL)
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.writeObjects(urls as [NSURL])
                    self.statusLabel.stringValue = localized("copyComplete", listing.entries.count)
                case .failure(let error):
                    self.statusLabel.stringValue = error.message
                }
            }
        }
    }

    private func collectFileURLs(in directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles],
            errorHandler: nil
        ) else {
            return []
        }
        return enumerator.compactMap { item -> URL? in
            guard let fileURL = item as? URL else { return nil }
            let isRegularFile = (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            return isRegularFile ? fileURL : nil
        }
    }

    /// Duplicate: for each selected file, stage a `.duplicate` op cloning the
    /// existing package entry to a non-colliding sibling path.
    @objc private func duplicateClickedItems() {
        let files = clickedNodes().filter { !$0.isDirectory && $0 !== rootNode && !$0.path.isEmpty }
        guard !files.isEmpty else {
            return
        }

        var count = 0
        mutateStagedOperations(actionName: localized("undoDuplicate"), animated: true) {
            for node in files {
                let target = uniqueDuplicateTarget(for: node.path)
                let record = StagedOperationRecord(
                    file: "",
                    target: target,
                    action: .duplicate,
                    size: node.size,
                    sourceName: (node.path as NSString).lastPathComponent,
                    sourcePath: node.path
                )
                stagedOperations.append(record)
                count += 1
            }
        }
        statusLabel.stringValue = localized("duplicateStaged", count)
    }

    /// Build a non-colliding "<name> copy.<ext>" sibling path, considering both
    /// existing package entries and already-staged targets.
    private func uniqueDuplicateTarget(for path: String, additionalTaken: Set<String> = []) -> String {
        let nsPath = path as NSString
        let directory = nsPath.deletingLastPathComponent
        let fileName = nsPath.lastPathComponent as NSString
        let ext = fileName.pathExtension
        let base = fileName.deletingPathExtension

        func assemble(_ stem: String) -> String {
            let leaf = ext.isEmpty ? stem : "\(stem).\(ext)"
            return directory.isEmpty ? leaf : "\(directory)/\(leaf)"
        }

        let stagedTargets = Set(stagedOperations.map { $0.target })
        func isTaken(_ candidate: String) -> Bool {
            return existingPackagePaths.contains(candidate)
                || stagedTargets.contains(candidate)
                || additionalTaken.contains(candidate)
        }

        var candidate = assemble("\(base) copy")
        if !isTaken(candidate) {
            return candidate
        }
        var counter = 2
        repeat {
            candidate = assemble("\(base) copy \(counter)")
            counter += 1
        } while isTaken(candidate)
        return candidate
    }

    /// Delete: stage a `.delete` op for each selected node. Directory nodes
    /// expand to deletes for every file descendant.
    @objc private func deleteClickedItems() {
        var paths: [String] = []
        var seen = Set<String>()
        for node in clickedNodes() {
            for path in deletablePaths(for: node) where seen.insert(path).inserted {
                paths.append(path)
            }
        }
        guard !paths.isEmpty else {
            return
        }
        // Stage the deletes, then slide the matching rows out of the tree instead
        // of hard-reloading — a smooth, Finder-like disappearance.
        mutateStagedOperations(actionName: localized("undoDelete"), animated: true) {
            applyStagedDeletes(for: paths)
        }
        statusLabel.stringValue = localized("deleteStaged", paths.count)
    }

    /// Resolve the concrete package file paths a delete on `node` should remove.
    private func deletablePaths(for node: PackageTreeNode) -> [String] {
        if node === rootNode {
            return []
        }
        if node.isDirectory {
            return fileDescendantPaths(of: node)
        }
        return node.path.isEmpty ? [] : [node.path]
    }

    private func fileDescendantPaths(of node: PackageTreeNode) -> [String] {
        var paths: [String] = []
        for child in node.children {
            if child.isDirectory {
                paths.append(contentsOf: fileDescendantPaths(of: child))
            } else if !child.path.isEmpty {
                paths.append(child.path)
            }
        }
        return paths
    }

    /// Append `.delete` ops for `paths` into `stagedOperations`, superseding any
    /// prior staged write to the same path. Pure model mutation — the caller
    /// wraps it in `mutateStagedOperations` to handle undo and the UI refresh.
    private func applyStagedDeletes(for paths: [String]) {
        for path in paths {
            // Drop any prior staged op writing to this path; delete supersedes it.
            stagedOperations.removeAll { $0.target == path && $0.action != .delete }
            if stagedOperations.contains(where: { $0.target == path && $0.action == .delete }) {
                continue
            }
            stagedOperations.append(
                StagedOperationRecord(
                    file: "",
                    target: path,
                    action: .delete,
                    size: 0,
                    sourceName: "",
                    sourcePath: ""
                )
            )
        }
    }

    private func stageDeletes(for paths: [String]) {
        guard !paths.isEmpty else {
            return
        }
        mutateStagedOperations(actionName: localized("undoDelete"), animated: true) {
            applyStagedDeletes(for: paths)
        }
    }

    private func extractSelectedPackageItems(paths: [String], destinationURL: URL) {
        guard !paths.isEmpty else {
            return
        }

        statusLabel.stringValue = localized("extractingPck", paths.count)
        let packageURL = package.url
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = PckCoreClient.extractPaths(
                packageURL: packageURL,
                destinationURL: destinationURL,
                paths: paths
            )

            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let listing):
                    self.statusLabel.stringValue = localized(
                        "extractComplete",
                        listing.entries.count,
                        destinationURL.lastPathComponent
                    )
                case .failure(let error):
                    self.statusLabel.stringValue = error.message
                }
            }
        }
    }

    /// Remove staged operations (driven by the Changes panel's per-row removal).
    func removeStagedOperations(at indexes: IndexSet) {
        let valid = indexes.filter { $0 >= 0 && $0 < stagedOperations.count }
        guard !valid.isEmpty else {
            return
        }
        mutateStagedOperations(actionName: localized("undoRemoveChange"), animated: true) {
            for index in valid.sorted(by: >) {
                stagedOperations.remove(at: index)
            }
        }
    }

    func backupPreferenceDidChange() {
        // The backup preference is read at pack time; nothing to recompute here.
    }

    // MARK: - Restore from backup

    /// The most recent `.bak` sitting next to this package, if any. Backups are
    /// named `<package>.<timestamp>.bak` by the Rust core's `create_pck_backup`.
    private func latestBackupURL() -> URL? {
        let directory = package.url.deletingLastPathComponent()
        let prefix = package.url.lastPathComponent + "."   // e.g. "game.pck."
        let candidates = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let backups = candidates.filter { url in
            let name = url.lastPathComponent
            return name.hasPrefix(prefix) && name.hasSuffix(".bak")
        }
        // Prefer the embedded timestamp; fall back to filesystem mtime.
        return backups.max { lhs, rhs in
            let lts = Self.backupTimestamp(lhs), rts = Self.backupTimestamp(rhs)
            if lts != rts { return lts < rts }
            return Self.modificationDate(lhs) < Self.modificationDate(rhs)
        }
    }

    /// Extract the millisecond timestamp embedded in `<package>.<timestamp>.bak`.
    private static func backupTimestamp(_ url: URL) -> UInt64 {
        let withoutBak = (url.lastPathComponent as NSString).deletingPathExtension // "<package>.<ts>"
        let stamp = (withoutBak as NSString).pathExtension                          // "<ts>"
        return UInt64(stamp) ?? 0
    }

    private static func modificationDate(_ url: URL) -> Date {
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    @objc func restoreBackupFromMenu(_ sender: Any?) {
        guard let backup = latestBackupURL() else {
            statusLabel.stringValue = localized("restoreBackupNone")
            return
        }
        let date = Self.modificationDate(backup)
        let dateText = DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)

        let alert = NSAlert()
        alert.messageText = localized("restoreBackupConfirm", package.displayName)
        alert.informativeText = localized("restoreBackupInfo", dateText)
        alert.alertStyle = .warning
        alert.addButton(withTitle: localized("restoreBackupButton"))
        alert.addButton(withTitle: localized("cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        do {
            // Stage the backup as a sibling temp file, then atomically swap it in
            // so a crash can't leave a half-written package. The .bak is copied,
            // not moved, so it remains available for a future restore.
            let destination = package.url
            let staging = destination.deletingLastPathComponent()
                .appendingPathComponent(".pckbottle-restore-\(UUID().uuidString)")
            try FileManager.default.copyItem(at: backup, to: staging)
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
        } catch {
            statusLabel.stringValue = error.localizedDescription
            return
        }

        // The restored package is the new truth: drop all pending edits + undo.
        stagedOperations.removeAll()
        view.window?.undoManager?.removeAllActions()
        pendingStatusMessage = localized("restoreBackupDone", dateText)
        updateChangesUI()
        loadPackageContents()
    }

    @objc func packChanges() {
        guard !stagedOperations.isEmpty else {
            return
        }
        guard confirmPackChanges() else {
            return
        }

        let operations = stagedOperations.map { record in
            PckOperationPayload(
                kind: record.action.coreKind,
                file: record.file,
                sourcePath: record.sourcePath,
                target: record.target
            )
        }
        let backupOriginal = isBackupEnabled
        preservedEditorWindowFrame = view.window?.frame
        setPacking(true, message: localized("writingChanges", operations.count, package.displayName))

        let packageURL = package.url
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = PckCoreClient.repack(
                packageURL: packageURL,
                backupOriginal: backupOriginal,
                operations: operations
            )

                DispatchQueue.main.async {
                    guard let self else { return }
                    self.setPacking(false, message: "")
                    switch result {
                    case .success(let log):
                        let summary = self.summarizePackResult(log: log)
                        self.pendingStatusMessage = summary
                        self.stagedOperations.removeAll()
                        self.view.window?.undoManager?.removeAllActions()
                        self.updateChangesUI()
                        self.statusLabel.stringValue = summary
                        self.loadPackageContents()
                    case .failure(let error):
                        self.statusLabel.stringValue = error.message
                        self.restorePreservedEditorWindowFrame()
                    }
                }
        }
    }

    func readStagedItems(from draggingInfo: NSDraggingInfo) -> [SourceDragPayload] {
        let pasteboard = draggingInfo.draggingPasteboard
        var payloads: [SourceDragPayload] = []
        var sawInternalPayload = false

        for item in pasteboard.pasteboardItems ?? [] {
            if let data = item.data(forType: .pckBottleSourceItems),
               let payloadGroup = try? JSONDecoder().decode(SourceDragPayloadGroup.self, from: data) {
                payloads.append(contentsOf: payloadGroup.items)
                sawInternalPayload = true
                continue
            }

            if let data = item.data(forType: .pckBottleSourceItem),
               let payload = try? JSONDecoder().decode(SourceDragPayload.self, from: data) {
                payloads.append(payload)
                sawInternalPayload = true
                continue
            }
        }

        // External file URLs are the primary path: `readObjects([NSURL.self])`
        // correctly decodes paths containing spaces/non-ASCII characters, which
        // `URL(string:)` silently drops.
        if !sawInternalPayload {
            let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
            let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
            payloads.append(contentsOf: urls.filter { $0.isFileURL }.flatMap(Self.expandExternalSourceURL))
        }

        return payloads
    }

    /// Stage external file/folder URLs (e.g. dropped onto the left Changes pane)
    /// as ADDs at the package root, reusing the tree's smart folder mapping.
    func stageExternalURLs(_ urls: [URL]) {
        let items = urls.filter { $0.isFileURL }.flatMap(Self.expandExternalSourceURL)
        guard !items.isEmpty else {
            return
        }
        stage(items: items, under: nil)
    }

    private func stage(items: [SourceDragPayload], under node: PackageTreeNode?) {
        let targetDirectory = packageTargetDirectory(for: node)
        // Unwrap a pure distribution wrapper (e.g. `translation/`) so its contents
        // land at the target, while keeping real package folders (`scenarios/`).
        let effectivePaths = unwrapWrapperPrefixes(items.map { $0.relativePath })
        let newOperations = zip(items, effectivePaths).map { item, relativePath -> StagedOperationRecord in
            let target = stageTarget(relativePath: relativePath, under: node, itemCount: items.count)
            return StagedOperationRecord(
                file: item.file,
                target: target,
                action: stageAction(for: target),
                size: item.size,
                sourceName: URL(fileURLWithPath: item.file).lastPathComponent
            )
        }

        let replaceTotal = newOperations.filter { $0.action == .replaceExisting }.count
        let undoName = replaceTotal == newOperations.count && replaceTotal > 0
            ? localized("undoReplace")
            : localized("undoAdd")
        mutateStagedOperations(actionName: undoName, animated: true) {
            for operation in newOperations {
                if let index = stagedOperations.firstIndex(where: { $0.target == operation.target }) {
                    stagedOperations[index] = operation
                } else {
                    stagedOperations.append(operation)
                }
            }
        }

        let replaceCount = newOperations.filter { $0.action == .replaceExisting }.count
        let addCount = newOperations.count - replaceCount
        statusLabel.stringValue = localized(
            "stagedStatus",
            newOperations.count,
            targetDirectory.isEmpty ? packageRootTitle() : targetDirectory,
            replaceCount,
            addCount
        )
    }

    private func stageTarget(relativePath: String, under node: PackageTreeNode?, itemCount: Int) -> String {
        if let node = node, !node.isDirectory, itemCount == 1 {
            return node.path
        }
        return combinePackagePath(directory: packageTargetDirectory(for: node), relativePath: relativePath)
    }

    /// Strip the leading folder component shared by ALL dropped items when that
    /// folder is not itself a package folder — i.e. unwrap a distribution wrapper
    /// like `translation/` so dropping the whole russifier folder still maps its
    /// contents onto the matching package paths. Real package folders (e.g.
    /// `scenarios/`, which DOES exist in the package) are preserved, so nesting is
    /// never flattened. Repeats to peel a doubly-nested wrapper.
    private func unwrapWrapperPrefixes(_ paths: [String]) -> [String] {
        guard !paths.isEmpty else {
            return paths
        }
        let packageTopLevels = Set(existingPackagePaths.compactMap {
            $0.split(separator: "/").first.map(String.init)
        })
        var result = paths
        while true {
            var wrapper: String?
            var allNested = true
            for path in result {
                let parts = path.split(separator: "/")
                guard parts.count >= 2 else {
                    allNested = false
                    break
                }
                let first = String(parts[0])
                if let existing = wrapper {
                    if existing != first {
                        allNested = false
                        break
                    }
                } else {
                    wrapper = first
                }
            }
            guard allNested, let common = wrapper, !packageTopLevels.contains(common) else {
                break
            }
            result = result.map { String($0.dropFirst(common.count + 1)) }
        }
        return result
    }

    private func stageAction(for target: String) -> StagedAction {
        return existingPackagePaths.contains(target) ? .replaceExisting : .addNew
    }

    private func packageTargetDirectory(for node: PackageTreeNode?) -> String {
        guard let node = node else {
            return ""
        }
        if node.isDirectory {
            return node.path
        }
        return parentPackagePath(node.path)
    }

    private func updateChangesUI(animated: Bool = false) {
        rebuildProjection(animated: animated)
        changesPanel?.render(operations: stagedOperations)
    }

    // MARK: - Undoable mutations

    /// Apply a staging mutation and register an undo that restores the prior
    /// `stagedOperations` snapshot. The redo is registered inside the undo block
    /// (standard pattern) so ⌘⇧Z reapplies the change. When `animated`, the tree
    /// refresh slides changed rows in/out instead of hard-reloading.
    private func mutateStagedOperations(actionName: String, animated: Bool = false, _ mutate: () -> Void) {
        let before = stagedOperations
        mutate()
        registerUndo(actionName: actionName, restore: before, animated: animated)
        updateChangesUI(animated: animated)
    }

    private func registerUndo(actionName: String, restore: [StagedOperationRecord], animated: Bool) {
        guard let undoManager = view.window?.undoManager else {
            return
        }
        undoManager.registerUndo(withTarget: self) { target in
            // Undo: snapshot current (for redo), restore prior, re-register.
            let current = target.stagedOperations
            target.stagedOperations = restore
            target.registerUndo(actionName: actionName, restore: current, animated: animated)
            // Undo/redo animate the same way the original action did, so the row
            // a ⌘Z brings back (or removes) slides rather than snapping.
            target.updateChangesUI(animated: animated)
        }
        undoManager.setActionName(actionName)
    }

    private var isBackupEnabled: Bool {
        return changesPanel?.isBackupEnabled ?? true
    }

    /// A comma-joined human summary of the staged operations broken down by
    /// kind (e.g. "1 заменить, 2 удалить, 1 дублировать"), listing only the
    /// kinds that actually occur so deletes/duplicates are never mislabelled as
    /// "added".
    private func stagedCountSummary() -> String {
        let counts: [(StagedAction, String)] = [
            (.replaceExisting, "countReplace"),
            (.addNew, "countAdd"),
            (.delete, "countDelete"),
            (.duplicate, "countDuplicate"),
        ]
        let parts = counts.compactMap { action, key -> String? in
            let count = stagedOperations.filter { $0.action == action }.count
            return count > 0 ? localized(key, count) : nil
        }
        return parts.joined(separator: ", ")
    }

    private func confirmPackChanges() -> Bool {
        let hasReplace = stagedOperations.contains { $0.action == .replaceExisting }
        let backupText = isBackupEnabled
            ? localized("backupOn")
            : localized("backupOff")

        let alert = NSAlert()
        alert.messageText = localized("packConfirm", stagedOperations.count, package.displayName)
        alert.informativeText = localized("packConfirmInfo", stagedCountSummary(), backupText)
        alert.alertStyle = hasReplace ? .warning : .informational
        alert.addButton(withTitle: localized("packChanges"))
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func summarizePackResult(log: String) -> String {
        let firstLine = log.split(separator: "\n").first.map(String.init)
        let backupText = isBackupEnabled ? localized("backupOnShort") : localized("backupOffShort")
        let resultText = firstLine?.isEmpty == false ? " \(firstLine!)" : ""
        return localized("packResult", stagedOperations.count, stagedCountSummary(), backupText, resultText)
    }

    private func setPacking(_ isPacking: Bool, message: String) {
        self.isPacking = isPacking
        if !message.isEmpty {
            statusLabel.stringValue = message
        }
        changesPanel?.setPacking(isPacking)
    }

    private func packageRootTitle() -> String {
        return localized("packageRoot")
    }

    private func packageRootSubtitle(itemCount: Int) -> String {
        return localized("packageRootSubtitle", itemCount, package.location)
    }

    private func packageNodeTitle(for node: PackageTreeNode) -> String {
        return node === rootNode ? packageRootTitle() : node.name
    }

    private func packageExportPaths(for node: PackageTreeNode) -> [String] {
        if node === rootNode {
            return Array(existingPackagePaths).sorted()
        }
        return node.path.isEmpty ? [] : [node.path]
    }

    private func packageStatus(itemCount: Int) -> String {
        return localized("packageStatus", itemCount, package.sizeText, package.location)
    }

    private func restorePreservedEditorWindowFrame() {
        guard let frame = preservedEditorWindowFrame, let window = view.window else {
            return
        }
        window.setFrame(frame, display: true)
        preservedEditorWindowFrame = nil
    }

    @objc private func applyLocalization() {
        titleLabel.stringValue = package.displayName
        nameColumn.title = localized("name")
        sizeColumn.title = localized("size")
        outlineView.menu = makeOutlineMenu()
        updateChangesUI()
        if !isPacking, pendingStatusMessage == nil {
            statusLabel.stringValue = loadedItemCount == 0 ? localized("readingPackage") : packageStatus(itemCount: loadedItemCount)
        }
    }

    private static func expandExternalSourceURL(_ url: URL) -> [SourceDragPayload] {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        if !isDirectory {
            return [makeExternalPayload(url: url, root: url.deletingLastPathComponent())]
        }

        // CRITICAL: do NOT pass `.skipsHiddenFiles`. Godot keeps every imported
        // texture in a DOT-directory — `res://.import/` on Godot 3 (`.stex`) and
        // `res://.godot/imported/` on Godot 4 (`.ctex`). Skipping hidden files
        // silently drops that whole directory, so a localization mod's graphics
        // never make it into the pack and the game keeps showing the originals
        // (the classic "translation applies but textures don't" bug). We instead
        // exclude only OS/VCS junk that must never be packed.
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [],
            errorHandler: nil
        ) else {
            return []
        }

        // A dropped folder keeps its OWN name in the staged path (Finder/`cp`
        // semantics): dropping `scenarios/` maps to `scenarios/…`, preserving the
        // package's nesting. (A pure distribution wrapper like `translation/` is
        // unwrapped later in `stage(_:under:)`, which knows the package layout.)
        // The `root` is the dropped folder's PARENT so its name is retained.
        let nameRoot = url.deletingLastPathComponent()
        return enumerator.compactMap { item -> SourceDragPayload? in
            guard let fileURL = item as? URL else {
                return nil
            }
            let isRegularFile = (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            guard isRegularFile, !isPackagingJunk(fileURL) else {
                return nil
            }
            return makeExternalPayload(url: fileURL, root: nameRoot)
        }
    }

    /// OS/VCS noise that must never be staged into a PCK: macOS Finder metadata
    /// and AppleDouble resource forks, Windows thumbnails, and version-control
    /// directories. Everything else — including Godot's hidden `.import`/`.godot`
    /// folders — is legitimate package content.
    private static func isPackagingJunk(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if name.hasPrefix("._") {
            return true
        }
        let junkFiles: Set<String> = [".DS_Store", ".localized", "Thumbs.db", "desktop.ini"]
        if junkFiles.contains(name) {
            return true
        }
        let junkDirs: Set<String> = [".git", ".svn", ".hg", "__MACOSX"]
        return url.pathComponents.contains { junkDirs.contains($0) }
    }

    private static func makeExternalPayload(url: URL, root: URL) -> SourceDragPayload {
        let size = UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        return SourceDragPayload(
            file: url.path,
            relativePath: relativePath(from: root, to: url),
            size: size
        )
    }

    private static func buildTree(from entries: [PckEntryPayload]) -> [PackageTreeNode] {
        let root = PackageTreeNode(name: "Package root", path: "", isDirectory: true)

        for entry in entries {
            let parts = entry.path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
            guard !parts.isEmpty else {
                continue
            }

            var cursor = root
            for index in parts.indices {
                let name = parts[index]
                let path = parts[...index].joined(separator: "/")
                let isLeaf = index == parts.index(before: parts.endIndex)
                let isDirectory = !isLeaf || entry.kind == "directory"

                if let existing = cursor.children.first(where: { $0.name == name && $0.isDirectory == isDirectory }) {
                    cursor = existing
                    if isLeaf {
                        existing.size = entry.size
                    }
                    continue
                }

                let node = PackageTreeNode(name: name, path: path, isDirectory: isDirectory, size: isLeaf ? entry.size : 0)
                cursor.children.append(node)
                cursor = node
            }
        }

        sortTree(root)
        return root.children
    }

    private static func sortTree(_ node: PackageTreeNode) {
        node.children.sort { left, right in
            if left.isDirectory != right.isDirectory {
                return left.isDirectory
            }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
        node.children.forEach(sortTree)
    }
}

