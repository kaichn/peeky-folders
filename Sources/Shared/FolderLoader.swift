import Foundation
import UniformTypeIdentifiers

enum FolderLoader {
    static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey,
        .creationDateKey, .localizedTypeDescriptionKey, .contentTypeKey,
    ]

    static func entry(for url: URL) -> Entry {
        let v = try? url.resourceValues(forKeys: Set(keys))
        let isDir = v?.isDirectory ?? false
        return Entry(
            name: url.lastPathComponent,
            fileURL: url,
            archivePath: nil,
            isDirectory: isDir,
            isPackage: v?.isPackage ?? false,
            kind: v?.localizedTypeDescription ?? (isDir ? "Folder" : "Document"),
            utType: v?.contentType,
            size: isDir ? nil : v?.fileSize.map(Int64.init),
            modified: v?.contentModificationDate,
            created: v?.creationDate
        )
    }

    static func children(of dir: Entry, showHidden: Bool) throws -> [Entry] {
        guard let url = dir.fileURL else { return dir.children ?? [] }
        let urls = try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys,
            options: showHidden ? [] : [.skipsHiddenFiles])
        return urls.map(entry(for:))
    }

    /// Recursive size of a folder using fts (much faster than FileManager enumeration).
    /// Returns nil when cancelled.
    static func directorySize(path: String, isCancelled: () -> Bool) -> Int64? {
        guard let cpath = strdup(path) else { return nil }
        defer { free(cpath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cpath, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR, nil) else { return nil }
        defer { fts_close(fts) }
        var total: Int64 = 0
        var n = 0
        while let ent = fts_read(fts) {
            n += 1
            if n & 1023 == 0, isCancelled() { return nil }
            switch Int32(ent.pointee.fts_info) {
            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                if let st = ent.pointee.fts_statp { total += Int64(st.pointee.st_size) }
            default:
                break
            }
        }
        return total
    }
}
