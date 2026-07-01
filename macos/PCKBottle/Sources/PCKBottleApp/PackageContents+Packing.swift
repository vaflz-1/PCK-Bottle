import AppKit
import CoreServices
import UniformTypeIdentifiers

extension PackageContentsViewController {

    // MARK: - Restore from backup

    /// The most recent `.bak` sitting next to this package, if any. Backups are
    /// named `<package>.<timestamp>.bak` by the Rust core's `create_pck_backup`.
    func latestBackupURL() -> URL? {
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
    static func backupTimestamp(_ url: URL) -> UInt64 {
        let withoutBak = (url.lastPathComponent as NSString).deletingPathExtension // "<package>.<ts>"
        let stamp = (withoutBak as NSString).pathExtension                          // "<ts>"
        return UInt64(stamp) ?? 0
    }

    static func modificationDate(_ url: URL) -> Date {
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

    func stage(items: [SourceDragPayload], under node: PackageTreeNode?) {
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

    func stageTarget(relativePath: String, under node: PackageTreeNode?, itemCount: Int) -> String {
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
    func unwrapWrapperPrefixes(_ paths: [String]) -> [String] {
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

    func stageAction(for target: String) -> StagedAction {
        return existingPackagePaths.contains(target) ? .replaceExisting : .addNew
    }

    func packageTargetDirectory(for node: PackageTreeNode?) -> String {
        guard let node = node else {
            return ""
        }
        if node.isDirectory {
            return node.path
        }
        return parentPackagePath(node.path)
    }

    func updateChangesUI(animated: Bool = false) {
        rebuildProjection(animated: animated)
        changesPanel?.render(operations: stagedOperations)
    }

    // MARK: - Undoable mutations

    /// Apply a staging mutation and register an undo that restores the prior
    /// `stagedOperations` snapshot. The redo is registered inside the undo block
    /// (standard pattern) so ⌘⇧Z reapplies the change. When `animated`, the tree
    /// refresh slides changed rows in/out instead of hard-reloading.
    func mutateStagedOperations(actionName: String, animated: Bool = false, _ mutate: () -> Void) {
        let before = stagedOperations
        mutate()
        registerUndo(actionName: actionName, restore: before, animated: animated)
        updateChangesUI(animated: animated)
    }

    func registerUndo(actionName: String, restore: [StagedOperationRecord], animated: Bool) {
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

    var isBackupEnabled: Bool {
        return changesPanel?.isBackupEnabled ?? true
    }

    /// A comma-joined human summary of the staged operations broken down by
    /// kind (e.g. "1 заменить, 2 удалить, 1 дублировать"), listing only the
    /// kinds that actually occur so deletes/duplicates are never mislabelled as
    /// "added".
    func stagedCountSummary() -> String {
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

    func confirmPackChanges() -> Bool {
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

    func summarizePackResult(log: String) -> String {
        let firstLine = log.split(separator: "\n").first.map(String.init)
        let backupText = isBackupEnabled ? localized("backupOnShort") : localized("backupOffShort")
        let resultText = firstLine?.isEmpty == false ? " \(firstLine!)" : ""
        return localized("packResult", stagedOperations.count, stagedCountSummary(), backupText, resultText)
    }

    func setPacking(_ isPacking: Bool, message: String) {
        self.isPacking = isPacking
        if !message.isEmpty {
            statusLabel.stringValue = message
        }
        changesPanel?.setPacking(isPacking)
    }

    func packageRootTitle() -> String {
        return localized("packageRoot")
    }

    func packageRootSubtitle(itemCount: Int) -> String {
        return localized("packageRootSubtitle", itemCount, package.location)
    }

    func packageNodeTitle(for node: PackageTreeNode) -> String {
        return node === rootNode ? packageRootTitle() : node.name
    }

    func packageExportPaths(for node: PackageTreeNode) -> [String] {
        if node === rootNode {
            return Array(existingPackagePaths).sorted()
        }
        return node.path.isEmpty ? [] : [node.path]
    }

    func packageStatus(itemCount: Int) -> String {
        return localized("packageStatus", itemCount, package.sizeText, package.location)
    }

    func restorePreservedEditorWindowFrame() {
        guard let frame = preservedEditorWindowFrame, let window = view.window else {
            return
        }
        window.setFrame(frame, display: true)
        preservedEditorWindowFrame = nil
    }

    @objc func applyLocalization() {
        titleLabel.stringValue = package.displayName
        nameColumn.title = localized("name")
        sizeColumn.title = localized("size")
        outlineView.menu = makeOutlineMenu()
        updateChangesUI()
        if !isPacking, pendingStatusMessage == nil {
            statusLabel.stringValue = loadedItemCount == 0 ? localized("readingPackage") : packageStatus(itemCount: loadedItemCount)
        }
    }

    static func expandExternalSourceURL(_ url: URL) -> [SourceDragPayload] {
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
    static func isPackagingJunk(_ url: URL) -> Bool {
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

    static func makeExternalPayload(url: URL, root: URL) -> SourceDragPayload {
        let size = UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        return SourceDragPayload(
            file: url.path,
            relativePath: relativePath(from: root, to: url),
            size: size
        )
    }
}
