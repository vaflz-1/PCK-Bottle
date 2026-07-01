import AppKit
import CoreServices
import UniformTypeIdentifiers

extension PackageContentsViewController {

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

    func parentNode(of target: PackageTreeNode, in node: PackageTreeNode? = nil) -> PackageTreeNode? {
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
}
