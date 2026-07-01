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

