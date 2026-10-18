import AppKit
import UniformTypeIdentifiers

/// One row in the browser: either a real file system item (`fileURL`)
/// or an item inside an archive (`archivePath`).
final class Entry: NSObject {
    let name: String
    let fileURL: URL?
    let archivePath: String?
    let isDirectory: Bool
    let isPackage: Bool
    let kind: String
    let utType: UTType?
    var size: Int64?
    var itemCount: Int?
    var modified: Date?
    var created: Date?
    var children: [Entry]?          // nil = not loaded yet (real folders load lazily)
    var icon: NSImage?
    var thumbnail: NSImage?
    var thumbnailSide: CGFloat = 0  // largest side requested so far
    var browsesPackages = false     // inside an app bundle, nested bundles open like folders too

    init(name: String, fileURL: URL?, archivePath: String?, isDirectory: Bool, isPackage: Bool,
         kind: String, utType: UTType?, size: Int64?, modified: Date?, created: Date?) {
        self.name = name
        self.fileURL = fileURL
        self.archivePath = archivePath
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.kind = kind
        self.utType = utType
        self.size = size
        self.modified = modified
        self.created = created
    }

    /// Folders you can browse into. App bundles and other packages are treated like files,
    /// except when previewing a bundle itself.
    var isFolderLike: Bool { isDirectory && (!isPackage || browsesPackages) }

    var displayPath: String { fileURL?.path ?? archivePath ?? name }
}

enum IconCache {
    private static var byType: [String: NSImage] = [:]

    static func icon(for e: Entry) -> NSImage {
        if let url = e.fileURL {
            if let i = e.icon { return i }
            let i = NSWorkspace.shared.icon(forFile: url.path)
            e.icon = i
            return i
        }
        let type: UTType = e.isDirectory ? .folder : (e.utType ?? .data)
        if let i = byType[type.identifier] { return i }
        let i = NSWorkspace.shared.icon(for: type)
        byType[type.identifier] = i
        return i
    }
}
