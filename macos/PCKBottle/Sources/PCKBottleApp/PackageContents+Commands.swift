import AppKit
import CoreServices
import UniformTypeIdentifiers

extension PackageContentsViewController {

    // MARK: - Keyboard shortcut entry points (operate on current selection)

    func deleteSelectedItems() { deleteClickedItems() }
    func duplicateSelectedItems() { duplicateClickedItems() }
    func copySelectedItems() { copyClickedItems() }
    func extractSelectedItemsViaPanel() { extractClickedItems() }

    // MARK: - Extraction (right-click "Extract to…")

    @objc func extractClickedItems() {
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
    func clickedNodes() -> [PackageTreeNode] {
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
    func clickedExtractionPaths() -> [String] {
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

    func clipboardHasFileURLs() -> Bool {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: options)
    }

    /// Paste: stage any file/folder URLs on the system clipboard, into the
    /// selected/clicked folder when one is targeted, otherwise package root.
    /// Unlike a drag (which replaces a matching path), paste keeps BOTH copies:
    /// a name collision is renamed "<name> copy" — the classic Finder behaviour —
    /// so a ⌘C/⌘V round-trip never silently overwrites the original.
    @objc func pasteFromClipboard() {
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
    @objc func moveClickedItems() {
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
    @objc func copyClickedItems() {
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

    func collectFileURLs(in directory: URL) -> [URL] {
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
    @objc func duplicateClickedItems() {
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
    func uniqueDuplicateTarget(for path: String, additionalTaken: Set<String> = []) -> String {
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
    @objc func deleteClickedItems() {
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
    func deletablePaths(for node: PackageTreeNode) -> [String] {
        if node === rootNode {
            return []
        }
        if node.isDirectory {
            return fileDescendantPaths(of: node)
        }
        return node.path.isEmpty ? [] : [node.path]
    }

    func fileDescendantPaths(of node: PackageTreeNode) -> [String] {
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
    func applyStagedDeletes(for paths: [String]) {
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

    func stageDeletes(for paths: [String]) {
        guard !paths.isEmpty else {
            return
        }
        mutateStagedOperations(actionName: localized("undoDelete"), animated: true) {
            applyStagedDeletes(for: paths)
        }
    }

    func extractSelectedPackageItems(paths: [String], destinationURL: URL) {
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

}
