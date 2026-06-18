import AppKit

struct PackageCandidate {
    let url: URL
    let sourceURL: URL
    let sourceName: String
    let displayName: String
    let location: String
    let sizeText: String

    var key: String {
        return url.standardizedFileURL.path
    }
}

extension NSPasteboard.PasteboardType {
    static let pckBottleSourceItem = NSPasteboard.PasteboardType("com.godotpckstudio.pckbottle.source-item")
    static let pckBottleSourceItems = NSPasteboard.PasteboardType("com.godotpckstudio.pckbottle.source-items")
}

struct SourceDragPayload: Codable {
    let file: String
    let relativePath: String
    let size: UInt64
}

struct SourceDragPayloadGroup: Codable {
    let items: [SourceDragPayload]
}

struct PckOperationPayload: Encodable {
    let kind: String
    let file: String
    let sourcePath: String
    let target: String

    init(kind: String = "", file: String = "", sourcePath: String = "", target: String) {
        self.kind = kind
        self.file = file
        self.sourcePath = sourcePath
        self.target = target
    }
}

/// Whether a staged operation overwrites an existing PCK entry, adds a new one,
/// removes an entry, or duplicates an existing entry within the package.
enum StagedAction {
    case replaceExisting
    case addNew
    case delete
    case duplicate

    var localizedDescription: String {
        switch self {
        case .replaceExisting:
            return localized("replaceExisting")
        case .addNew:
            return localized("addNew")
        case .delete:
            return localized("actionDelete")
        case .duplicate:
            return localized("actionDuplicate")
        }
    }

    /// The `kind` value the Rust core expects for this action.
    var coreKind: String {
        switch self {
        case .delete:
            return "delete"
        case .duplicate:
            return "copy"
        case .replaceExisting, .addNew:
            return ""
        }
    }
}

struct StagedOperationRecord {
    let file: String
    let target: String
    let action: StagedAction
    let size: UInt64
    let sourceName: String
    let sourcePath: String

    init(
        file: String,
        target: String,
        action: StagedAction,
        size: UInt64,
        sourceName: String,
        sourcePath: String = ""
    ) {
        self.file = file
        self.target = target
        self.action = action
        self.size = size
        self.sourceName = sourceName
        self.sourcePath = sourcePath
    }

    var sizeText: String {
        guard action != .delete else {
            return ""
        }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

/// How a projected tree node should be tinted to reflect its pending state.
enum PendingTint {
    case none
    case added      // green: new path, no existing entry
    case replaced   // yellow: add that overwrites an existing entry
    case duplicate  // purple: clone within the package
    case copied     // blue: pasted/copied entry (currently unused)

    var color: NSColor {
        switch self {
        case .none:
            return .labelColor
        case .added:
            return .systemGreen
        case .replaced:
            return .systemYellow
        case .duplicate:
            return .systemPurple
        case .copied:
            return .systemBlue
        }
    }
}

final class PackageTreeNode {
    let name: String
    let path: String
    let isDirectory: Bool
    var size: UInt64
    var children: [PackageTreeNode] = []
    /// Pending-state tint for the projected tree. Recomputed on every projection.
    var tint: PendingTint = .none

    init(name: String, path: String, isDirectory: Bool, size: UInt64 = 0) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
    }

    var sizeText: String {
        guard !isDirectory else {
            return ""
        }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

struct SourceFileRecord {
    let url: URL
    let displayPath: String
    let isDirectory: Bool
    let size: UInt64
    let sizeText: String
}
