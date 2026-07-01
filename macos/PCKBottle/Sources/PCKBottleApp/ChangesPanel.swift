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

    let titleLabel = NSTextField(labelWithString: "")
    let outlineView = NSOutlineView()
    let emptyLabel = NSTextField(labelWithString: "")
    let warningBanner = NSView()
    let warningLabel = NSTextField(labelWithString: "")
    // The checkbox itself carries no title; a separate, always-readable label
    // sits beside it (fixes the previously invisible checkbox caption).
    let backupCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let backupLabel = NSTextField(labelWithString: "Backup original")
    let packButton = NSButton(title: "Pack Changes", target: nil, action: nil)
    let progressIndicator = NSProgressIndicator()
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("change"))

    var operations: [StagedOperationRecord] = []
    var groups: [ChangeGroup] = []
    // Reused per-kind group instances so the outline keeps stable item identity
    // (and therefore its expand/collapse state) across re-renders.
    var groupCache: [StagedAction: ChangeGroup] = [:]
    // Kinds the user has manually collapsed; persisted across re-renders so a
    // staged action no longer pops every group back open.
    var collapsedActions: Set<StagedAction> = []
    // Guards programmatic expand/collapse from being recorded as user intent.
    var isAdjustingExpansion = false
    // The change list's top is pinned under the warning banner when it is shown,
    // and directly under the title when it is hidden — so a hidden banner leaves
    // no dead gap and the list rises to sit right under "Changes".
    var scrollTopUnderWarning: NSLayoutConstraint?
    var scrollTopUnderTitle: NSLayoutConstraint?
    // Group ordering used when building the section list.
    static let groupOrder: [StagedAction] = [.replaceExisting, .addNew, .delete, .duplicate]

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

    func makeRowMenu() -> NSMenu {
        let menu = NSMenu()
        let removeItem = NSMenuItem(title: localized("remove"), action: #selector(removeClickedRow), keyEquivalent: "")
        removeItem.target = self
        menu.addItem(removeItem)
        return menu
    }

    /// Rebuild the kind groups from the staged operations, preserving the global
    /// operation index so per-row removal maps back to the controller.
    func rebuildGroups() {
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
    func applyExpansionState() {
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

    @objc func backupToggled() {
        controller?.backupPreferenceDidChange()
    }

    @objc func backupLabelClicked() {
        guard backupCheckbox.isEnabled else { return }
        backupCheckbox.state = backupCheckbox.state == .on ? .off : .on
        backupToggled()
    }

    @objc func packPressed() {
        controller?.packChanges()
    }

    @objc func removeClickedRow() {
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

    @objc func applyLocalization() {
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
