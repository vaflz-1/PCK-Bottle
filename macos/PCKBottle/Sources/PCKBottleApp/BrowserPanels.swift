import AppKit
import CoreServices
import UniformTypeIdentifiers

final class GameSourceViewController: NSViewController, DropTargetViewDelegate {
    var onOpenRequested: (() -> Void)?
    var onURLsAccepted: (([URL]) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let openButton = NSButton(title: "Open Game or PCK", target: nil, action: nil)
    private let supportButton = NSButton()
    private let dropView = DropTargetView()
    private var loadedSourceURL: URL?
    private var loadedPackageCount = 0

    override func loadView() {
        let container = NSVisualEffectView()
        container.material = .sidebar
        container.blendingMode = .withinWindow
        container.state = .active

        titleLabel.font = NSFont.systemFont(ofSize: 24, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let titleRow = NSStackView(views: [titleLabel])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 8
        titleRow.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 3
        // Without this, a long dropped .app/.pck name makes the status label
        // demand its full intrinsic width and the whole window jumps wider.
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        openButton.target = self
        openButton.action = #selector(openButtonPressed)
        openButton.bezelStyle = .rounded
        openButton.setButtonType(.momentaryPushIn)

        dropView.delegate = self

        // Unobtrusive donation entry pinned to the sidebar bottom: an outline
        // heart + "Support", styled like a quiet link. Opens Ko-fi on click.
        supportButton.isBordered = false
        supportButton.bezelStyle = .inline
        supportButton.imagePosition = .imageLeading
        supportButton.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        supportButton.target = self
        supportButton.action = #selector(supportPressed)
        supportButton.translatesAutoresizingMaskIntoConstraints = false
        if #available(macOS 11.0, *) {
            // Outline heart (SF Symbol). The title carries a ♡ fallback below.
            supportButton.image = NSImage(systemSymbolName: "heart", accessibilityDescription: localized("supportShort"))
        }
        if #available(macOS 10.14, *) {
            supportButton.contentTintColor = .secondaryLabelColor
        }

        let stack = NSStackView(views: [titleRow, statusLabel, openButton, dropView])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(stack)
        container.addSubview(supportButton)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            titleRow.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            titleRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            openButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            dropView.heightAnchor.constraint(greaterThanOrEqualToConstant: 168),
            dropView.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            dropView.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            supportButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            supportButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            // Let the drop zone grow to fill the sidebar down to just above Support,
            // so it reads as a large, inviting target instead of a small box.
            dropView.bottomAnchor.constraint(equalTo: supportButton.topAnchor, constant: -16),
        ])

        view = container
    }

    @objc private func supportPressed() {
        openKoFi()
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
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func setLoadedSource(_ url: URL?, packageCount: Int) {
        loadedSourceURL = url
        loadedPackageCount = packageCount
        updateSourceStatus()
    }

    func dropTargetView(_ view: DropTargetView, accepted urls: [URL]) {
        onURLsAccepted?(urls)
    }

    @objc private func openButtonPressed() {
        onOpenRequested?()
    }

    @objc private func applyLocalization() {
        titleLabel.stringValue = localized("games")
        openButton.title = localized("openGameOrPck")
        dropView.title = localized("dropAppOrPck")
        if #available(macOS 11.0, *) {
            supportButton.title = localized("supportShort")
        } else {
            supportButton.title = "♡ " + localized("supportShort")
        }
        updateSourceStatus()
    }

    private func updateSourceStatus() {
        guard let url = loadedSourceURL else {
            // The drop zone below already prompts "Drop .app or .pck here", so
            // keep the subtitle hidden until a source loads to avoid duplication.
            statusLabel.stringValue = ""
            statusLabel.isHidden = true
            return
        }
        statusLabel.isHidden = false
        if loadedPackageCount == 0 {
            statusLabel.stringValue = "\(url.lastPathComponent) - \(localized("noPckFound"))"
        } else {
            statusLabel.stringValue = localized("pckFound", url.lastPathComponent, loadedPackageCount)
        }
    }
}

final class PackageListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var onOpenPackage: ((PackageCandidate) -> Void)?

    private var packages: [PackageCandidate] = []
    private let titleLabel = NSTextField(labelWithString: "")
    private let tableView = NSTableView()
    private let countLabel = NSTextField(labelWithString: "")
    private let openButton = NSButton(title: "Open Selected PCK", target: nil, action: nil)
    private let scrollView = NSScrollView()
    private let emptyStateLabel = NSTextField(labelWithString: "")
    private let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
    private let locationColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("location"))
    private let sizeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))

    override func loadView() {
        let container = NSView()

        titleLabel.font = NSFont.systemFont(ofSize: 24, weight: .semibold)
        titleLabel.textColor = .labelColor

        countLabel.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        countLabel.textColor = .secondaryLabelColor

        openButton.target = self
        openButton.action = #selector(openSelectedPackage)
        openButton.isEnabled = false

        let toolbar = NSStackView(views: [titleLabel, countLabel, openButton])
        toolbar.orientation = .horizontal
        // Baseline-align so "Packages" and the count sit on the same text line,
        // matching the left panel's title baseline.
        toolbar.alignment = .firstBaseline
        toolbar.spacing = 16
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        nameColumn.width = 240

        locationColumn.width = 420

        sizeColumn.width = 96

        tableView.addTableColumn(nameColumn)
        tableView.addTableColumn(locationColumn)
        tableView.addTableColumn(sizeColumn)
        tableView.headerView = NSTableHeaderView()
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.doubleAction = #selector(openSelectedPackage)
        tableView.allowsMultipleSelection = false
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 32

        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.documentView = tableView
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // Shown centered in place of the empty striped table when there are no
        // packages yet — cleaner than a grid of blank alternating rows.
        emptyStateLabel.font = NSFont.systemFont(ofSize: 15, weight: .regular)
        emptyStateLabel.textColor = .secondaryLabelColor
        emptyStateLabel.alignment = .center
        emptyStateLabel.lineBreakMode = .byWordWrapping
        emptyStateLabel.maximumNumberOfLines = 2
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(toolbar)
        container.addSubview(scrollView)
        container.addSubview(emptyStateLabel)

        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            toolbar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            toolbar.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 20),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            emptyStateLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyStateLabel.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 24),
            emptyStateLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),
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
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func setPackages(_ packages: [PackageCandidate]) {
        self.packages = packages
        updatePackageSummary()
        openButton.isEnabled = false
        tableView.reloadData()
        if packages.count == 1 {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            openButton.isEnabled = true
        } else {
            tableView.deselectAll(nil)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        return packages.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < packages.count else {
            return nil
        }

        let package = packages[row]
        let identifier = tableColumn?.identifier ?? NSUserInterfaceItemIdentifier("name")
        let text: String

        switch identifier.rawValue {
        case "location":
            text = package.location
        case "size":
            text = package.sizeText
        default:
            text = package.displayName
        }

        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? NSTableCellView()
        cell.identifier = identifier

        let label: NSTextField
        if let existingLabel = cell.textField {
            label = existingLabel
        } else {
            label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        label.stringValue = text
        label.lineBreakMode = .byTruncatingMiddle
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        openButton.isEnabled = selectedPackage() != nil
    }

    private func selectedPackage() -> PackageCandidate? {
        let row = tableView.selectedRow
        guard row >= 0, row < packages.count else {
            return nil
        }
        return packages[row]
    }

    @objc func openSelectedPackage() {
        guard let package = selectedPackage() else {
            return
        }
        onOpenPackage?(package)
    }

    @objc private func applyLocalization() {
        titleLabel.stringValue = localized("packages")
        openButton.title = localized("openSelectedPck")
        nameColumn.title = "PCK"
        locationColumn.title = localized("location")
        sizeColumn.title = localized("size")
        updatePackageSummary()
        tableView.reloadData()
    }

    private func updatePackageSummary() {
        if packages.isEmpty {
            countLabel.stringValue = localized("noPckFound")
        } else if packages.count == 1 {
            countLabel.stringValue = localized("onePckFile")
        } else {
            countLabel.stringValue = localized("manyPckFiles", packages.count)
        }
        updateEmptyState()
    }

    /// Swap the striped table for a centered hint when there is nothing to list.
    private func updateEmptyState() {
        let isEmpty = packages.isEmpty
        scrollView.isHidden = isEmpty
        emptyStateLabel.isHidden = !isEmpty
        emptyStateLabel.stringValue = localized("noPckHint")
    }
}

