import AppKit

extension ChangesViewController {

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !isAdjustingExpansion,
              let group = notification.userInfo?["NSObject"] as? ChangeGroup else {
            return
        }
        collapsedActions.remove(group.action)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !isAdjustingExpansion,
              let group = notification.userInfo?["NSObject"] as? ChangeGroup else {
            return
        }
        collapsedActions.insert(group.action)
    }

    func groupTitle(for group: ChangeGroup) -> String {
        let count = group.operations.count
        switch group.action {
        case .replaceExisting:
            return localized("groupReplace", count)
        case .addNew:
            return localized("groupAdd", count)
        case .delete:
            return localized("groupDelete", count)
        case .duplicate:
            return localized("groupDuplicate", count)
        }
    }

    func accentColor(for action: StagedAction) -> NSColor {
        switch action {
        case .replaceExisting:
            return .systemYellow
        case .addNew:
            return .systemGreen
        case .delete:
            return .systemRed
        case .duplicate:
            return .systemPurple
        }
    }

    // MARK: - NSOutlineView data source / delegate (collapsible groups)

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            return groups.count
        }
        if let group = item as? ChangeGroup {
            return group.operations.count
        }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return groups[index]
        }
        if let group = item as? ChangeGroup {
            let entry = group.operations[index]
            return ChangeOperationRow(index: entry.index, record: entry.record, action: group.action)
        }
        return groups[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        return item is ChangeGroup
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        if item is ChangeGroup {
            return 30
        }
        if let row = item as? ChangeOperationRow {
            return row.record.sourceName.isEmpty ? 26 : 40
        }
        return 26
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let group = item as? ChangeGroup {
            return groupHeaderCell(group: group)
        }
        if let row = item as? ChangeOperationRow {
            return changePathCell(record: row.record, action: row.action)
        }
        return nil
    }

    func groupHeaderCell(group: ChangeGroup) -> NSView {
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: groupTitle(for: group))
        label.font = NSFont.systemFont(ofSize: 12, weight: .bold)
        label.textColor = accentColor(for: group.action)
        label.translatesAutoresizingMaskIntoConstraints = false
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.layer?.backgroundColor = accentColor(for: group.action).cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(dot)
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            dot.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    /// A staged-operation row. The parent group header already names the kind
    /// (Replace/Add/Delete/Duplicate), so the row itself carries no badge — just
    /// a small kind-coloured accent dot, the target path, and the source name.
    func changePathCell(record: StagedOperationRecord, action: StagedAction) -> NSView {
        let cell = NSTableCellView()
        let accent = accentColor(for: action)

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.layer?.backgroundColor = accent.withAlphaComponent(0.9).cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false

        let pathLabel = NSTextField(labelWithString: record.target)
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        pathLabel.textColor = .labelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        cell.addSubview(dot)
        cell.addSubview(pathLabel)
        cell.textField = pathLabel

        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            pathLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            pathLabel.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
        ])

        if record.sourceName.isEmpty {
            // Single line: center the path and dot vertically.
            NSLayoutConstraint.activate([
                pathLabel.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                dot.centerYAnchor.constraint(equalTo: pathLabel.centerYAnchor),
            ])
        } else {
            let sourceLabel = NSTextField(labelWithString: localized("fromSource", record.sourceName))
            sourceLabel.translatesAutoresizingMaskIntoConstraints = false
            sourceLabel.font = NSFont.systemFont(ofSize: 10, weight: .regular)
            sourceLabel.textColor = .secondaryLabelColor
            sourceLabel.lineBreakMode = .byTruncatingMiddle
            sourceLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            cell.addSubview(sourceLabel)
            NSLayoutConstraint.activate([
                pathLabel.topAnchor.constraint(equalTo: cell.topAnchor, constant: 5),
                dot.centerYAnchor.constraint(equalTo: pathLabel.centerYAnchor),
                sourceLabel.leadingAnchor.constraint(equalTo: pathLabel.leadingAnchor),
                sourceLabel.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                sourceLabel.topAnchor.constraint(equalTo: pathLabel.bottomAnchor, constant: 2),
            ])
        }
        return cell
    }
}
