import AppKit

/// Drives the whole update flow: check → prompt → download → mount → swap the
/// running bundle → relaunch. One instance is owned by `AppDelegate`. Model and
/// networking types live in `UpdateChecker.swift`.
final class UpdateCoordinator {
    private let lastLaunchCheckKey = "PCKBottleLastUpdateCheck"
    private let launchThrottle: TimeInterval = 60 * 60 * 24  // once per day
    private var progressWindow: NSWindow?
    private var isBusy = false

    // MARK: Entry points

    /// Silent, throttled check used at launch. Never surfaces "up to date" or
    /// network errors — it only speaks up when an update is actually available,
    /// honouring the app's no-nagging philosophy.
    func checkOnLaunchIfDue() {
        let defaults = UserDefaults.standard
        let now = Date().timeIntervalSince1970
        let last = defaults.double(forKey: lastLaunchCheckKey)
        guard now - last >= launchThrottle else { return }
        defaults.set(now, forKey: lastLaunchCheckKey)
        check(userInitiated: false)
    }

    /// Full check. When `userInitiated` is true, up-to-date and error states are
    /// reported to the user; when false, only an available update is shown.
    func check(userInitiated: Bool) {
        guard !isBusy else { return }
        isBusy = true
        UpdateService.fetchLatestRelease { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isBusy = false
                switch result {
                case .success(let release):
                    self.handle(release: release, userInitiated: userInitiated)
                case .failure(let error):
                    if userInitiated {
                        self.presentError(error.localizedDescription)
                    }
                }
            }
        }
    }

    // MARK: Decision

    private func handle(release: GitHubRelease, userInitiated: Bool) {
        guard !release.draft, let latest = release.version else {
            if userInitiated { presentUpToDate() }
            return
        }
        guard latest > AppInfo.currentVersion else {
            if userInitiated { presentUpToDate() }
            return
        }
        presentUpdateAvailable(release: release, latest: latest)
    }

    // MARK: Alerts

    private func presentUpdateAvailable(release: GitHubRelease, latest: AppVersion) {
        let alert = NSAlert()
        alert.messageText = localized("updateAvailableTitle", latest.description)
        var info = localized("updateAvailableInfo", latest.description, AppInfo.currentVersion.description)
        if let notes = release.body?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            info += "\n\n" + String(notes.prefix(600))
        }
        alert.informativeText = info
        alert.addButton(withTitle: localized("updateNow"))
        alert.addButton(withTitle: localized("viewRelease"))
        alert.addButton(withTitle: localized("later"))

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            startInstall(release: release)
        case .alertSecondButtonReturn:
            if let url = URL(string: release.htmlURL) {
                NSWorkspace.shared.open(url)
            }
        default:
            break
        }
    }

    private func presentUpToDate() {
        let alert = NSAlert()
        alert.messageText = localized("upToDateTitle")
        alert.informativeText = localized("upToDateInfo", AppInfo.currentVersion.description)
        alert.addButton(withTitle: localized("ok"))
        alert.runModal()
    }

    private func presentError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = localized("updateCheckFailed")
        alert.informativeText = message
        alert.addButton(withTitle: localized("ok"))
        alert.runModal()
    }

    // MARK: Install orchestration

    private func startInstall(release: GitHubRelease) {
        // Auto-install only makes sense from a real .app bundle we can replace.
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else {
            fallbackToBrowser(release: release, error: .notBundled)
            return
        }
        let parent = bundleURL.deletingLastPathComponent().path
        guard FileManager.default.isWritableFile(atPath: parent) else {
            fallbackToBrowser(release: release, error: .notWritable)
            return
        }
        guard let asset = release.dmgAsset, let assetURL = URL(string: asset.browserDownloadURL) else {
            fallbackToBrowser(release: release, error: .noAsset)
            return
        }

        showProgress(localized("updateDownloading"))
        URLSession.shared.downloadTask(with: assetURL) { [weak self] tempURL, _, error in
            guard let self = self else { return }
            if let error = error {
                DispatchQueue.main.async {
                    self.hideProgress()
                    self.presentError(error.localizedDescription)
                }
                return
            }
            guard let tempURL = tempURL else {
                DispatchQueue.main.async {
                    self.hideProgress()
                    self.presentError(UpdateError.network("Download produced no file.").localizedDescription)
                }
                return
            }
            self.installDownloadedDMG(at: tempURL, bundleURL: bundleURL)
        }.resume()
    }

    /// Runs on the download callback's background queue: give the file a `.dmg`
    /// suffix, mount it, stage the enclosed `.app`, validate it, then hand off to
    /// the swap-and-relaunch step on the main queue.
    private func installDownloadedDMG(at tempURL: URL, bundleURL: URL) {
        let fileManager = FileManager.default
        let work = fileManager.temporaryDirectory
            .appendingPathComponent("PCKBottleUpdate-\(ProcessInfo.processInfo.globallyUniqueString)", isDirectory: true)
        let dmgURL = work.appendingPathComponent("update.dmg")
        let mountURL = work.appendingPathComponent("mnt", isDirectory: true)
        let stageURL = work.appendingPathComponent("staged", isDirectory: true)

        func fail(_ message: String) {
            try? fileManager.removeItem(at: work)
            DispatchQueue.main.async {
                self.hideProgress()
                self.presentError(message)
            }
        }

        do {
            try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: mountURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: stageURL, withIntermediateDirectories: true)
            try fileManager.moveItem(at: tempURL, to: dmgURL)
        } catch {
            fail(UpdateError.install(error.localizedDescription).localizedDescription)
            return
        }

        DispatchQueue.main.async { self.updateProgress(localized("updateInstalling")) }

        // Mount read-only without touching Finder.
        let attach = runProcess("/usr/bin/hdiutil",
                                ["attach", dmgURL.path, "-nobrowse", "-noverify", "-readonly",
                                 "-mountpoint", mountURL.path])
        guard attach.status == 0 else {
            fail(UpdateError.install("hdiutil attach failed: \(attach.stderr)").localizedDescription)
            return
        }

        // Locate the .app inside the mounted image.
        let mountedApp = (try? fileManager.contentsOfDirectory(at: mountURL, includingPropertiesForKeys: nil))?
            .first { $0.pathExtension == "app" }
        guard let mountedApp = mountedApp else {
            _ = runProcess("/usr/bin/hdiutil", ["detach", mountURL.path, "-force"])
            fail(UpdateError.install("No .app found inside the disk image.").localizedDescription)
            return
        }

        // Copy the app out of the image, then detach.
        let stagedApp = stageURL.appendingPathComponent(mountedApp.lastPathComponent)
        let copy = runProcess("/usr/bin/ditto", [mountedApp.path, stagedApp.path])
        _ = runProcess("/usr/bin/hdiutil", ["detach", mountURL.path, "-force"])
        guard copy.status == 0 else {
            fail(UpdateError.install("Could not copy the new app: \(copy.stderr)").localizedDescription)
            return
        }

        // Sanity-check the staged bundle before we overwrite ourselves with it.
        guard validateStagedApp(at: stagedApp) else {
            fail(UpdateError.install("The downloaded app failed validation.").localizedDescription)
            return
        }

        DispatchQueue.main.async {
            self.swapAndRelaunch(stagedApp: stagedApp, destination: bundleURL, workDir: work)
        }
    }

    /// Confirms the staged bundle is really PCK Bottle and is at least as new as
    /// what we're running — never downgrade or install an unrelated app.
    private func validateStagedApp(at appURL: URL) -> Bool {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let identifier = plist["CFBundleIdentifier"] as? String,
              identifier == AppInfo.bundleIdentifier else {
            return false
        }
        if let shortVersion = plist["CFBundleShortVersionString"] as? String,
           let staged = AppVersion(shortVersion) {
            return staged >= AppInfo.currentVersion
        }
        return true
    }

    /// Writes a detached helper script that waits for this process to exit, swaps
    /// the bundle, clears quarantine, and relaunches — then terminates the app.
    private func swapAndRelaunch(stagedApp: URL, destination: URL, workDir: URL) {
        let scriptURL = workDir.appendingPathComponent("swap.sh")
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        #!/bin/bash
        set -e
        PID="\(pid)"
        SRC="\(stagedApp.path)"
        DEST="\(destination.path)"
        WORK="\(workDir.path)"
        # Wait for PCK Bottle to fully quit before replacing its bundle.
        while /bin/kill -0 "$PID" 2>/dev/null; do /bin/sleep 0.2; done
        /bin/sleep 0.3
        /bin/rm -rf "$DEST"
        /usr/bin/ditto "$SRC" "$DEST"
        /usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
        /usr/bin/open "$DEST"
        /bin/rm -rf "$WORK"
        """

        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        } catch {
            hideProgress()
            presentError(UpdateError.install(error.localizedDescription).localizedDescription)
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [scriptURL.path]
        do {
            try task.run()
        } catch {
            hideProgress()
            presentError(UpdateError.install(error.localizedDescription).localizedDescription)
            return
        }

        hideProgress()
        NSApp.terminate(nil)
    }

    private func fallbackToBrowser(release: GitHubRelease, error: UpdateError) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = localized("updateCheckFailed")
        alert.informativeText = (error.errorDescription ?? "") + "\n\n" + localized("updateOpenPagePrompt")
        alert.addButton(withTitle: localized("viewRelease"))
        alert.addButton(withTitle: localized("cancel"))
        if alert.runModal() == .alertFirstButtonReturn, let url = URL(string: release.htmlURL) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Progress window

    private func showProgress(_ message: String) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 96),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "PCK Bottle"
        window.isReleasedWhenClosed = false
        window.level = .floating

        let label = NSTextField(labelWithString: message)
        label.alignment = .center
        label.tag = 1
        label.translatesAutoresizingMaskIntoConstraints = false

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.startAnimation(nil)
        spinner.translatesAutoresizingMaskIntoConstraints = false

        let content = window.contentView!
        content.addSubview(label)
        content.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            spinner.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            label.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 16),
        ])

        window.center()
        window.makeKeyAndOrderFront(nil)
        progressWindow = window
    }

    private func updateProgress(_ message: String) {
        (progressWindow?.contentView?.viewWithTag(1) as? NSTextField)?.stringValue = message
    }

    private func hideProgress() {
        progressWindow?.orderOut(nil)
        progressWindow = nil
    }

    // MARK: Process helper

    /// Runs a tool to completion, capturing stdout/stderr. Synchronous — call it
    /// off the main thread.
    @discardableResult
    private func runProcess(_ launchPath: String, _ arguments: [String]) -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            return (-1, "", error.localizedDescription)
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(data: outData, encoding: .utf8) ?? "",
            String(data: errData, encoding: .utf8) ?? ""
        )
    }
}
