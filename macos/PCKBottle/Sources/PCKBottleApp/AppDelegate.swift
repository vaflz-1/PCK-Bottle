import AppKit
import CoreServices
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var browserWindowController: BrowserWindowController?
    private let updateCoordinator = UpdateCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(rebuildLanguageMenuOnChange),
            name: .pckBottleLanguageDidChange,
            object: nil
        )
        ensureBrowserWindow()
        NSApp.activate(ignoringOtherApps: true)
        // Silent, throttled (once/day) check that only speaks up when a newer
        // release exists — no launch pop-ups when already up to date.
        updateCoordinator.checkOnLaunchIfDue()
    }

    @discardableResult
    private func ensureBrowserWindow() -> BrowserWindowController {
        if let controller = browserWindowController {
            return controller
        }
        let controller = BrowserWindowController()
        browserWindowController = controller
        controller.showWindow(self)
        return controller
    }

    /// Open .pck / .app documents passed by Finder ("Open With" or double-click,
    /// honouring the CFBundleDocumentTypes the bundle declares).
    func application(_ application: NSApplication, open urls: [URL]) {
        let supported = urls.filter {
            let ext = $0.pathExtension.lowercased()
            return ext == "pck" || ext == "app"
        }
        guard !supported.isEmpty else {
            return
        }
        let controller = ensureBrowserWindow()
        controller.window?.makeKeyAndOrderFront(self)
        NSApp.activate(ignoringOtherApps: true)
        controller.open(urls: supported)
    }

    @objc private func rebuildLanguageMenuOnChange() {
        rebuildLanguageMenu()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu(title: "PCK Bottle")
        appMenuItem.submenu = appMenu
        let aboutItem = NSMenuItem(title: localized("aboutApp"), action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        appMenu.addItem(aboutItem)
        appMenu.addItem(NSMenuItem.separator())
        // A single, unobtrusive donation entry — no launch pop-ups or nagging.
        let supportItem = NSMenuItem(title: localized("support"), action: #selector(openSupport), keyEquivalent: "")
        supportItem.target = self
        appMenu.addItem(supportItem)
        let updatesItem = NSMenuItem(title: localized("checkForUpdates"), action: #selector(checkForUpdates), keyEquivalent: "")
        updatesItem.target = self
        appMenu.addItem(updatesItem)
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "Quit PCK Bottle", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu
        let openItem = NSMenuItem(title: "Open", action: #selector(openDocument(_:)), keyEquivalent: "o")
        openItem.target = self
        fileMenu.addItem(openItem)

        fileMenu.addItem(NSMenuItem.separator())
        // Routes through the responder chain to the focused editor's
        // PackageContentsViewController; disabled when no .bak exists for it.
        let restoreItem = NSMenuItem(
            title: localized("restoreBackup"),
            action: NSSelectorFromString("restoreBackupFromMenu:"),
            keyEquivalent: "R"
        )
        restoreItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(restoreItem)

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        // Undo/Redo route through the responder chain to the editor window's
        // NSUndoManager (vended via windowWillReturnUndoManager).
        let undoItem = NSMenuItem(title: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        editMenu.addItem(undoItem)
        let redoItem = NSMenuItem(title: "Redo", action: NSSelectorFromString("redo:"), keyEquivalent: "Z")
        editMenu.addItem(redoItem)
        editMenu.addItem(NSMenuItem.separator())
        let selectAllActionName = "selectAll:"
        editMenu.addItem(NSMenuItem(title: "Select All", action: NSSelectorFromString(selectAllActionName), keyEquivalent: "a"))

        // Language menu in the menu bar (replaces the in-window globe button).
        let languageMenuItem = NSMenuItem()
        self.languageMenuItem = languageMenuItem
        mainMenu.addItem(languageMenuItem)
        rebuildLanguageMenu()

        NSApp.mainMenu = mainMenu
    }

    private var languageMenuItem: NSMenuItem?

    private func rebuildLanguageMenu() {
        guard let languageMenuItem = languageMenuItem else {
            return
        }
        let menu = makeLanguageMenu(target: self, action: #selector(selectLanguage(_:)))
        languageMenuItem.title = localized("language")
        languageMenuItem.submenu = menu
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        applySelectedLanguage(sender)
        rebuildLanguageMenu()
    }

    @objc private func openDocument(_ sender: Any?) {
        browserWindowController?.openPathPanelFromMenu()
    }

    @objc private func openSupport() {
        openKoFi()
    }

    @objc private func checkForUpdates() {
        updateCoordinator.check(userInitiated: true)
    }

    @objc private func showAbout() {
        let credits = NSMutableAttributedString(string: localized("aboutCredits") + "\n")
        let linkText = "github.com/\(AppInfo.repoOwner)/\(AppInfo.repoName)"
        let link = NSMutableAttributedString(string: linkText)
        if let url = URL(string: "https://github.com/\(AppInfo.repoOwner)/\(AppInfo.repoName)") {
            link.addAttribute(.link, value: url, range: NSRange(location: 0, length: link.length))
        }
        credits.append(link)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "PCK Bottle",
            .applicationVersion: AppInfo.currentVersion.description,
            .credits: credits,
        ])
    }
}

