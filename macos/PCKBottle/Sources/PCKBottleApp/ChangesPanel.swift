import AppKit
import CoreServices
import UniformTypeIdentifiers

final class ChangeGroup {
    let action: StagedAction
    var operations: [(index: Int, record: StagedOperationRecord)] = []

    init(action: StagedAction) {
        self.action = action
    }
}

/// Right column of the editor: a polished, collapsible review of staged
/// operations grouped by kind, plus the Pack controls. It is a thin
/// presentation layer; all staging, classification, and repack logic stays in
/// `PackageContentsViewController`.
///
/// Conforms to the table data-source/delegate protocols (kept for API
/// compatibility) but renders via an inner `NSOutlineView` for the groups.
final class ChangesViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate {
    weak var controller: PackageContentsViewController?

    private let titleLabel = NSTextField(labelWithString: "")
    private let outlineView = NSOutlineView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let warningBanner = NSView()
    private let warningLabel = NSTextField(labelWithString: "")
    // The checkbox itself carries no title; a separate, always-readable label
    // sits beside it (fixes the previously invisible checkbox caption).
    private let backupCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let backupLabel = NSTextField(labelWithString: "Backup original")
    private let packButton = NSButton(title: "Pack Changes", target: nil, action: nil)
    private let progressIndicator = NSProgressIndicator()
    private let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("change"))

    private var operations: [StagedOperationRecord] = []
    private var groups: [ChangeGroup] = []
    // Reused per-kind group instances so the outline keeps stable item identity
    // (and therefore its expand/collapse state) across re-renders.
    private var groupCache: [StagedAction: ChangeGroup] = [:]
    // Kinds the user has manually collapsed; persisted across re-renders so a
    // staged action no longer pops every group back open.
    private var collapsedActions: Set<StagedAction> = []
    // Guards programmatic expand/collapse from being recorded as user intent.
    private var isAdjustingExpansion = false
    // The change list's top is pinned under the warning banner when it is shown,
    // and directly under the title when it is hidden — so a hidden banner leaves
    // no dead gap and the list rises to sit right under "Changes".
    private var scrollTopUnderWarning: NSLayoutConstraint?
    private var scrollTopUnderTitle: NSLayoutConstraint?
    // Group ordering used when building the section list.
    private static let groupOrder: [StagedAction] = [.replaceExisting, .addNew, .delete, .duplicate]

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var isBackupEnabled: Bool {
        return backupCheckbox.state == .on
    }

    override func loadView() {
        let container = ChangesDropContainerView()
        container.material = .sidebar
        container.blendingMode = .behindWindow
        container.state = .followsWindowActiveState
        container.onURLsDropped = { [weak self] urls in
            self?.controller?.stageExternalURLs(urls)
        }

        titleLabel.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        warningBanner.wantsLayer = true
        warningBanner.layer?.cornerRadius = 7
        warningBanner.layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.18).cgColor
        warningBanner.translatesAutoresizingMaskIntoConstraints = false
        warningBanner.isHidden = true

        warningLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        warningLabel.textColor = .labelColor
        warningLabel.lineBreakMode = .byWordWrapping
        warningLabel.maximumNumberOfLines = 0
        warningLabel.translatesAutoresizingMaskIntoConstraints = false
        warningLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        warningBanner.addSubview(warningLabel)
        NSLayoutConstraint.activate([
            warningLabel.leadingAnchor.constraint(equalTo: warningBanner.leadingAnchor, constant: 10),
            warningLabel.trailingAnchor.constraint(equalTo: warningBanner.trailingAnchor, constant: -10),
            warningLabel.topAnchor.constraint(equalTo: warningBanner.topAnchor, constant: 8),
            warningLabel.bottomAnchor.constraint(equalTo: warningBanner.bottomAnchor, constant: -8),
        ])

        column.width = 300
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.delegate = self
        outlineView.dataSource = self
        outlineView.headerView = nil
        outlineView.rowSizeStyle = .custom
        outlineView.indentationPerLevel = 12
        outlineView.allowsMultipleSelection = true
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.backgroundColor = .clear
        outlineView.floatsGroupRows = false
        outlineView.menu = makeRowMenu()

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.documentView = outlineView
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.lineBreakMode = .byWordWrapping
        emptyLabel.maximumNumberOfLines = 0
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        backupCheckbox.state = .on
        backupCheckbox.target = self
        backupCheckbox.action = #selector(backupToggled)
        backupCheckbox.translatesAutoresizingMaskIntoConstraints = false
        backupCheckbox.setContentHuggingPriority(.required, for: .horizontal)

        backupLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        backupLabel.textColor = .labelColor
        backupLabel.translatesAutoresizingMaskIntoConstraints = false
        // Clicking the label also toggles the checkbox.
        let labelClick = NSClickGestureRecognizer(target: self, action: #selector(backupLabelClicked))
        backupLabel.addGestureRecognizer(labelClick)

        let backupRow = NSStackView(views: [backupCheckbox, backupLabel])
        backupRow.orientation = .horizontal
        backupRow.alignment = .centerY
        backupRow.spacing = 6
        backupRow.translatesAutoresizingMaskIntoConstraints = false
        backupLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        packButton.target = self
        packButton.action = #selector(packPressed)
        packButton.bezelStyle = .rounded
        packButton.keyEquivalent = "\r"
        packButton.isEnabled = false
        packButton.translatesAutoresizingMaskIntoConstraints = false

        progressIndicator.style = .bar
        progressIndicator.isIndeterminate = true
        progressIndicator.isHidden = false
        progressIndicator.alphaValue = 0
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false

        let footer = NSStackView(views: [backupRow, progressIndicator, packButton])
        footer.orientation = .vertical
        footer.alignment = .leading
        footer.spacing = 10
        footer.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(titleLabel)
        container.addSubview(warningBanner)
        container.addSubview(scrollView)
        container.addSubview(emptyLabel)
        container.addSubview(footer)

        let scrollTopUnderWarning = scrollView.topAnchor.constraint(equalTo: warningBanner.bottomAnchor, constant: 8)
        let scrollTopUnderTitle = scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12)
        self.scrollTopUnderWarning = scrollTopUnderWarning
        self.scrollTopUnderTitle = scrollTopUnderTitle

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            titleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),

            warningBanner.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            warningBanner.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            warningBanner.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),

            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            scrollTopUnderTitle,
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),

            emptyLabel.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 16),
            emptyLabel.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -16),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -18),
            progressIndicator.widthAnchor.constraint(equalTo: footer.widthAnchor),
            packButton.widthAnchor.constraint(equalTo: footer.widthAnchor),
        ])

        view = container
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
        render(operations: operations)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func makeRowMenu() -> NSMenu {
        let menu = NSMenu()
        let removeItem = NSMenuItem(title: localized("remove"), action: #selector(removeClickedRow), keyEquivalent: "")
        removeItem.target = self
        menu.addItem(removeItem)
        return menu
    }

    /// Rebuild the kind groups from the staged operations, preserving the global
    /// operation index so per-row removal maps back to the controller.
    private func rebuildGroups() {
        var byAction: [StagedAction: ChangeGroup] = [:]
        for (index, record) in operations.enumerated() {
            let group: ChangeGroup
            if let existing = byAction[record.action] {
                group = existing
            } else {
                // Reuse the cached instance for this kind so NSOutlineView sees the
                // same object across reloads and preserves its expansion state.
                let reused = groupCache[record.action] ?? ChangeGroup(action: record.action)
                reused.operations.removeAll(keepingCapacity: true)
                groupCache[record.action] = reused
                byAction[record.action] = reused
                group = reused
            }
            group.operations.append((index, record))
        }
        groups = Self.groupOrder.compactMap { byAction[$0] }
    }

    /// Expand or collapse each group to match the remembered `collapsedActions`,
    /// without recording the programmatic change as user intent.
    private func applyExpansionState() {
        isAdjustingExpansion = true
        for group in groups {
            if collapsedActions.contains(group.action) {
                outlineView.collapseItem(group)
            } else {
                outlineView.expandItem(group)
            }
        }
        isAdjustingExpansion = false
    }

    /// Refresh the panel from the authoritative staged operations.
    func render(operations: [StagedOperationRecord]) {
        self.operations = operations
        rebuildGroups()
        guard isViewLoaded else {
            return
        }
        outlineView.reloadData()
        applyExpansionState()
        let isEmpty = operations.isEmpty
        emptyLabel.isHidden = !isEmpty

        // The "no match" warning is only about add/replace path confusion;
        // deletes and duplicates neither trigger nor suppress it.
        let addLikeOps = operations.filter { $0.action == .addNew || $0.action == .replaceExisting }
        let replaceCount = addLikeOps.filter { $0.action == .replaceExisting }.count
        let showWarning = !addLikeOps.isEmpty && replaceCount == 0
        warningBanner.isHidden = !showWarning
        // Reclaim the banner's vertical space when hidden so the list sits right
        // under the title.
        scrollTopUnderWarning?.isActive = showWarning
        scrollTopUnderTitle?.isActive = !showWarning

        packButton.isEnabled = !isEmpty && !(controller?.isPacking ?? false)
    }

    func setPacking(_ isPacking: Bool) {
        progressIndicator.alphaValue = isPacking ? 1 : 0
        if isPacking {
            progressIndicator.startAnimation(self)
        } else {
            progressIndicator.stopAnimation(self)
        }
        packButton.isEnabled = !isPacking && !operations.isEmpty
        backupCheckbox.isEnabled = !isPacking
    }

    @objc private func backupToggled() {
        controller?.backupPreferenceDidChange()
    }

    @objc private func backupLabelClicked() {
        guard backupCheckbox.isEnabled else { return }
        backupCheckbox.state = backupCheckbox.state == .on ? .off : .on
        backupToggled()
    }

    @objc private func packPressed() {
        controller?.packChanges()
    }

    @objc private func removeClickedRow() {
        var targetIndexes = IndexSet()
        for row in outlineView.selectedRowIndexes {
            if let op = outlineView.item(atRow: row) as? ChangeOperationRow {
                targetIndexes.insert(op.index)
            }
        }
        let clicked = outlineView.clickedRow
        if clicked >= 0, let op = outlineView.item(atRow: clicked) as? ChangeOperationRow {
            targetIndexes.insert(op.index)
        }
        guard !targetIndexes.isEmpty else {
            return
        }
        controller?.removeStagedOperations(at: targetIndexes)
    }

    override func selectAll(_ sender: Any?) {
        outlineView.selectAll(sender)
    }

    @objc private func applyLocalization() {
        titleLabel.stringValue = localized("changes")
        backupLabel.stringValue = localized("backupOriginal")
        // Keep the checkbox title in sync too so accessibility reads a caption.
        backupCheckbox.title = ""
        packButton.title = localized("packChanges")
        emptyLabel.stringValue = localized("changesEmptyHint")
        warningLabel.stringValue = "⚠️ " + localized("noMatchWarning")
        outlineView.menu = makeRowMenu()
        outlineView.reloadData()
        applyExpansionState()
    }

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

    private func groupTitle(for group: ChangeGroup) -> String {
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

    private func accentColor(for action: StagedAction) -> NSColor {
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

    private func groupHeaderCell(group: ChangeGroup) -> NSView {
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
    private func changePathCell(record: StagedOperationRecord, action: StagedAction) -> NSView {
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

/// A single staged-operation row in the Changes outline. Carries the global
/// operation index so removal maps back to the controller's `stagedOperations`.
final class ChangeOperationRow {
    let index: Int
    let record: StagedOperationRecord
    let action: StagedAction

    init(index: Int, record: StagedOperationRecord, action: StagedAction) {
        self.index = index
        self.record = record
        self.action = action
    }
}

/// The package tree's outline view. Adds keyboard shortcuts (⌘⌫ delete, ⌘D
/// duplicate, ⌘C copy, ⌘E extract) operating on the current selection, and
/// selects the right-clicked row WITHOUT scrolling it into view so the tree
/// never jumps when a context menu is summoned.
