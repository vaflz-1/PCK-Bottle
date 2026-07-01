import AppKit
import CoreServices
import UniformTypeIdentifiers

extension PackageContentsViewController {

    // MARK: - Optimistic projection

    /// Recompute the displayed tree as the projection of `loadedEntries` through
    /// the staged `stagedOperations`. No disk writes happen here.
    ///
    /// When `animated` is true and only leaf rows changed under unchanged folders
    /// (the common case: a staged add, delete, duplicate, paste, or an undo of
    /// any of those), the rows slide in/out individually for a Finder-like feel.
    /// Anything structural (a folder appearing or disappearing) falls back to a
    /// plain reload, which is always correct.
    func rebuildProjection(animated: Bool = false) {
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
    func applyAttributes(_ attributes: [String: (size: UInt64, tint: PendingTint)]) {
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
    static func collectFilePaths(_ nodes: [PackageTreeNode]) -> Set<String> {
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
    static func collectDirPaths(_ nodes: [PackageTreeNode]) -> Set<String> {
        var paths = Set<String>()
        for node in nodes where node.isDirectory {
            paths.insert(node.path)
            paths.formUnion(collectDirPaths(node.children))
        }
        return paths
    }

    /// path -> (size, tint) for every file leaf in the target tree.
    static func attributeMap(for nodes: [PackageTreeNode]) -> [String: (size: UInt64, tint: PendingTint)] {
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
    static func fileInsertionIndex(for leaf: PackageTreeNode, in parent: PackageTreeNode) -> Int {
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
    static func buildProjectedTree(
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
    static func applyTints(to nodes: [PackageTreeNode], tints: [String: PendingTint]) {
        for node in nodes {
            node.tint = tints[node.path] ?? .none
            applyTints(to: node.children, tints: tints)
        }
    }

    // MARK: - Tree construction

    static func buildTree(from entries: [PckEntryPayload]) -> [PackageTreeNode] {
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

    static func sortTree(_ node: PackageTreeNode) {
        node.children.sort { left, right in
            if left.isDirectory != right.isDirectory {
                return left.isDirectory
            }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
        node.children.forEach(sortTree)
    }
}
