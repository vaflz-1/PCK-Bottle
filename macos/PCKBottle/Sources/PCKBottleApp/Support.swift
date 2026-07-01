import AppKit
import CoreServices
import UniformTypeIdentifiers

protocol DropTargetViewDelegate: AnyObject {
    func dropTargetView(_ view: DropTargetView, accepted urls: [URL])
}

func drawCenteredDropTitle(
    _ title: String,
    in bounds: NSRect,
    font: NSFont,
    color: NSColor
) {
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.alignment = .center
    paragraphStyle.lineBreakMode = .byWordWrapping

    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
        .paragraphStyle: paragraphStyle,
    ]
    let attributedTitle = NSAttributedString(string: title, attributes: attributes)
    let textBounds = bounds.insetBy(dx: 18, dy: 12)
    let measured = attributedTitle.boundingRect(
        with: textBounds.size,
        options: [.usesLineFragmentOrigin, .usesFontLeading]
    )
    let textHeight = min(ceil(measured.height), textBounds.height)
    let textRect = NSRect(
        x: textBounds.minX,
        y: max(textBounds.minY, bounds.midY - textHeight / 2),
        width: textBounds.width,
        height: textHeight + 2
    )
    attributedTitle.draw(
        with: textRect,
        options: [.usesLineFragmentOrigin, .usesFontLeading]
    )
}

func textCell(tableView: NSTableView, identifier: NSUserInterfaceItemIdentifier, text: String) -> NSTableCellView {
    let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView ?? NSTableCellView()
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

func iconTextCell(
    tableView: NSTableView,
    identifier: NSUserInterfaceItemIdentifier,
    text: String,
    node: PackageTreeNode
) -> NSTableCellView {
    let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView ?? NSTableCellView()
    cell.identifier = identifier

    let iconView: NSImageView
    if let existingIconView = cell.imageView {
        iconView = existingIconView
    } else {
        iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(iconView)
        cell.imageView = iconView
    }

    let label: NSTextField
    if let existingLabel = cell.textField {
        label = existingLabel
    } else {
        label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
    }

    if label.constraints.isEmpty {
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            iconView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
    }

    iconView.image = packageIcon(for: node)
    label.stringValue = text
    // Tint the row text to reflect its pending projection state.
    label.textColor = node.tint.color
    label.lineBreakMode = .byTruncatingMiddle
    return cell
}

func packageIcon(for node: PackageTreeNode) -> NSImage {
    let icon: NSImage
    if node.isDirectory {
        icon = NSWorkspace.shared.icon(forFileType: NSFileTypeForHFSTypeCode(OSType(kGenericFolderIcon)))
    } else {
        let fileType = (node.name as NSString).pathExtension.isEmpty
            ? "txt"
            : (node.name as NSString).pathExtension
        icon = NSWorkspace.shared.icon(forFileType: fileType)
    }
    icon.size = NSSize(width: 18, height: 18)
    return icon
}

/// Resolve a file-promise UTI for an extension. Uses `UTType` on macOS 11+
/// (`UTType(filenameExtension:)?.identifier`) and the CoreServices fallback on
/// older systems, defaulting to `public.data` when the extension is unknown.
func utiIdentifier(forExtension ext: String) -> String {
    let fallback = "public.data"
    guard !ext.isEmpty else {
        return fallback
    }
    if #available(macOS 11.0, *) {
        return UTType(filenameExtension: ext)?.identifier ?? fallback
    }
    if let uti = UTTypeCreatePreferredIdentifierForTag(
        kUTTagClassFilenameExtension,
        ext as CFString,
        nil
    )?.takeRetainedValue() as String? {
        return uti
    }
    return fallback
}

func combinePackagePath(directory: String, relativePath: String) -> String {
    let cleanDirectory = cleanPackagePath(directory)
    let cleanRelativePath = cleanPackagePath(relativePath)
    guard !cleanDirectory.isEmpty else {
        return cleanRelativePath
    }
    guard !cleanRelativePath.isEmpty else {
        return cleanDirectory
    }
    return "\(cleanDirectory)/\(cleanRelativePath)"
}

func parentPackagePath(_ path: String) -> String {
    let parts = cleanPackagePath(path).split(separator: "/").map(String.init)
    guard parts.count > 1 else {
        return ""
    }
    return parts.dropLast().joined(separator: "/")
}

func cleanPackagePath(_ path: String) -> String {
    let normalized = path.replacingOccurrences(of: "\\", with: "/")
    let parts = normalized.split(separator: "/").map(String.init)
    let safeParts = parts.filter { part in
        !part.isEmpty && part != "." && part != ".." && part != "res:"
    }
    return safeParts.joined(separator: "/")
}

func relativePath(from root: URL, to child: URL) -> String {
    let rootPath = root.standardizedFileURL.path
    let childPath = child.standardizedFileURL.path
    if childPath.hasPrefix(rootPath + "/") {
        return String(childPath.dropFirst(rootPath.count + 1))
    }
    return child.lastPathComponent
}

/// Open the project's Ko-fi page in the user's browser (optional donations).
func openKoFi() {
    if let url = URL(string: "https://ko-fi.com/vaflz") {
        NSWorkspace.shared.open(url)
    }
}

