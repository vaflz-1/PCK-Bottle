import AppKit
import CoreServices
import UniformTypeIdentifiers

final class BrowserWindowController: NSWindowController {
    init() {
        let browserViewController = BrowserViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = "PCK Bottle"
        window.contentMinSize = NSSize(width: 860, height: 560)
        window.center()
        window.contentViewController = browserViewController

        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func openPathPanelFromMenu() {
        (window?.contentViewController as? BrowserViewController)?.openPathPanelFromMenu()
    }

    func open(urls: [URL]) {
        (window?.contentViewController as? BrowserViewController)?.open(urls: urls)
    }
}

final class BrowserViewController: NSSplitViewController {
    private let sourceViewController = GameSourceViewController()
    private let packageListViewController = PackageListViewController()
    private var editorWindowsByPath: [String: EditorWindowController] = [:]

    override func viewDidLoad() {
        super.viewDidLoad()

        sourceViewController.onOpenRequested = { [weak self] in
            self?.openPathPanel()
        }
        sourceViewController.onURLsAccepted = { [weak self] urls in
            self?.loadPackages(from: urls)
        }
        packageListViewController.onOpenPackage = { [weak self] package in
            self?.openEditor(for: package)
        }

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sourceViewController)
        sidebarItem.minimumThickness = 300
        sidebarItem.maximumThickness = 360

        let packageItem = NSSplitViewItem(viewController: packageListViewController)
        packageItem.minimumThickness = 520

        addSplitViewItem(sidebarItem)
        addSplitViewItem(packageItem)
    }

    @objc private func openPathPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.allowedFileTypes = ["app", "pck"]
        panel.allowsOtherFileTypes = false
        panel.title = "Open Godot Game or PCK"
        panel.message = "Choose a Godot .app bundle or a loose .pck package."
        panel.prompt = "Open"

        if panel.runModal() == .OK, let url = panel.url {
            loadPackages(from: [url])
        }
    }

    func openPathPanelFromMenu() {
        openPathPanel()
    }

    func open(urls: [URL]) {
        loadPackages(from: urls)
    }

    private func loadPackages(from urls: [URL]) {
        let packages = scanForPackages(urls: urls)
        sourceViewController.setLoadedSource(urls.first, packageCount: packages.count)
        packageListViewController.setPackages(packages)
        if isDirectPckSelection(urls: urls, packages: packages), let package = packages.first {
            openEditor(for: package)
        }
    }

    private func isDirectPckSelection(urls: [URL], packages: [PackageCandidate]) -> Bool {
        guard urls.count == 1, packages.count == 1, let url = urls.first else {
            return false
        }
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        return url.pathExtension.lowercased() == "pck" && !isDirectory
    }

    func scanForPackages(urls: [URL]) -> [PackageCandidate] {
        var packages: [PackageCandidate] = []

        for url in urls {
            packages.append(contentsOf: scanForPackages(at: url))
        }

        return uniquePackages(packages).sorted { left, right in
            if left.sourceName != right.sourceName {
                return left.sourceName.localizedStandardCompare(right.sourceName) == .orderedAscending
            }
            return left.location.localizedStandardCompare(right.location) == .orderedAscending
        }
    }

    private func scanForPackages(at url: URL) -> [PackageCandidate] {
        let extensionName = url.pathExtension.lowercased()
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false

        if extensionName == "pck", !isDirectory {
            return [makePackage(url: url, sourceURL: url, location: url.lastPathComponent)]
        }

        if extensionName == "app" {
            return uniquePackages(
                scanAppBundlePackages(url)
                    + scanSiblingPackagesForAppBundle(url)
            )
        }

        if isDirectory {
            return scanPackages(in: url, sourceURL: url, locationRoot: url, skipPackageDescendants: true)
        }

        return []
    }

    private func scanAppBundlePackages(_ appURL: URL) -> [PackageCandidate] {
        let resourcesURL = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
        let resourcePackages = scanPackages(
            in: resourcesURL,
            sourceURL: appURL,
            locationRoot: appURL,
            skipPackageDescendants: true
        )

        guard resourcePackages.isEmpty else {
            return resourcePackages
        }

        return scanPackages(in: appURL, sourceURL: appURL, locationRoot: appURL, skipPackageDescendants: false)
    }

    private func scanSiblingPackagesForAppBundle(_ appURL: URL) -> [PackageCandidate] {
        let gameFolderURL = appURL.deletingLastPathComponent()
        return scanPackages(
            in: gameFolderURL,
            sourceURL: appURL,
            locationRoot: gameFolderURL,
            skipPackageDescendants: true
        )
    }

    private func scanPackages(
        in rootURL: URL,
        sourceURL: URL,
        locationRoot: URL,
        skipPackageDescendants: Bool
    ) -> [PackageCandidate] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles]
        if skipPackageDescendants {
            options.insert(.skipsPackageDescendants)
        }

        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: options,
            errorHandler: nil
        ) else {
            return []
        }

        return enumerator.compactMap { item -> PackageCandidate? in
            guard let fileURL = item as? URL else {
                return nil
            }

            let isRegularFile = (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            guard isRegularFile, fileURL.pathExtension.lowercased() == "pck" else {
                return nil
            }

            return makePackage(
                url: fileURL,
                sourceURL: sourceURL,
                location: relativePath(from: locationRoot, to: fileURL)
            )
        }
    }

    private func uniquePackages(_ packages: [PackageCandidate]) -> [PackageCandidate] {
        var seen = Set<String>()
        return packages.filter { package in
            let key = package.key
            guard !seen.contains(key) else {
                return false
            }
            seen.insert(key)
            return true
        }
    }

    private func makePackage(url: URL, sourceURL: URL, location: String) -> PackageCandidate {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
        return PackageCandidate(
            url: url,
            sourceURL: sourceURL,
            sourceName: sourceURL.lastPathComponent,
            displayName: url.lastPathComponent,
            location: location,
            sizeText: ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        )
    }

    private func relativePath(from root: URL, to child: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let childPath = child.standardizedFileURL.path
        if childPath.hasPrefix(rootPath + "/") {
            return String(childPath.dropFirst(rootPath.count + 1))
        }
        return child.lastPathComponent
    }

    private func openEditor(for package: PackageCandidate) {
        if let existingController = editorWindowsByPath[package.key], existingController.window != nil {
            existingController.showWindow(self)
            existingController.window?.makeKeyAndOrderFront(self)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = EditorWindowController(package: package)
        controller.onClose = { [weak self] in
            self?.editorWindowsByPath.removeValue(forKey: package.key)
        }
        editorWindowsByPath[package.key] = controller
        controller.showWindow(self)
    }
}

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
            dropView.heightAnchor.constraint(equalToConstant: 168),
            dropView.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            dropView.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            supportButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            supportButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
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
            statusLabel.stringValue = localized("dropAppOrPck")
            return
        }

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
        toolbar.alignment = .centerY
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

        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.documentView = tableView
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(toolbar)
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            toolbar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            toolbar.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 20),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
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
    }
}

