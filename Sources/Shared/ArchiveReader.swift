import Foundation
import UniformTypeIdentifiers

enum ArchiveError: LocalizedError {
    case cannotOpen(String)
    case tooLarge(Int64, Int64)

    var errorDescription: String? {
        switch self {
        case .cannotOpen(let why): return "Can't read this archive: \(why)"
        case .tooLarge(let size, let limit):
            let f = ByteCountFormatter()
            return "This archive (\(f.string(fromByteCount: size))) is larger than the archive size limit (\(f.string(fromByteCount: limit))). You can raise the limit in the ⚙︎ menu."
        }
    }
}

/// Lists archive contents with libarchive: zip/jar, tar, gz/tgz, bz2, xz, 7z, rar, cpio, iso, …
enum ArchiveReader {
    struct Item { var path: String; var isDir: Bool; var size: Int64?; var mtime: Date? }

    static func list(url: URL, showHidden: Bool) throws -> Entry {
        let items: [Item]
        if isSingleCompressedFile(url) {
            // foo.txt.gz is not an archive: show the single file inside.
            let inner = url.deletingPathExtension().lastPathComponent
            items = try read(url, raw: true).map { Item(path: inner, isDir: false, size: $0.size, mtime: $0.mtime) }
        } else {
            items = try read(url, raw: false)
        }
        return buildTree(items, rootName: url.lastPathComponent, showHidden: showHidden)
    }

    private static let compressorExtensions: Set<String> = ["gz", "gzip", "bz2", "xz", "lzma", "z", "lz", "lz4", "zst"]

    private static func isSingleCompressedFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        guard compressorExtensions.contains(url.pathExtension.lowercased()) else { return false }
        return !name.contains(".tar.") && !name.contains(".cpio.")
    }

    private static func read(_ url: URL, raw: Bool) throws -> [Item] {
        guard let a = archive_read_new() else { throw ArchiveError.cannotOpen("out of memory") }
        defer { archive_read_free(a) }
        archive_read_support_filter_all(a)
        if raw { archive_read_support_format_raw(a) } else { archive_read_support_format_all(a) }

        func lastError() -> String {
            archive_error_string(a).map { String(cString: $0) } ?? "unknown error"
        }
        guard archive_read_open_filename(a, url.path, 1 << 16) == 0 else {
            throw ArchiveError.cannotOpen(lastError())
        }
        var items: [Item] = []
        var entry: OpaquePointer?
        while true {
            let r = archive_read_next_header(a, &entry)
            if r == 1 { break }                          // ARCHIVE_EOF
            if r < -20 {                                 // ARCHIVE_FAILED / ARCHIVE_FATAL
                if items.isEmpty { throw ArchiveError.cannotOpen(lastError()) }
                break                                    // show what we got so far
            }
            guard let e = entry else { break }
            let isDir = (archive_entry_filetype(e) & 0o170000) == 0o040000
            var size: Int64? = archive_entry_size_is_set(e) != 0 ? archive_entry_size(e) : nil
            if raw {
                // Raw streams don't record their size; decompress once to count it.
                var total: Int64 = 0
                var buffer = [UInt8](repeating: 0, count: 1 << 16)
                while true {
                    let n = buffer.withUnsafeMutableBytes { archive_read_data(a, $0.baseAddress, $0.count) }
                    if n <= 0 { break }
                    total += Int64(n)
                }
                size = total
            }
            items.append(Item(
                path: decodeName(e),
                isDir: isDir,
                size: size,
                mtime: archive_entry_mtime_is_set(e) != 0 ? Date(timeIntervalSince1970: TimeInterval(archive_entry_mtime(e))) : nil
            ))
            if !raw { archive_read_data_skip(a) }
        }
        return items
    }

    /// Reads an archive once: returns every entry name, plus the contents of the entries
    /// `wanted` accepts (kept small: manifests and metadata, not payloads).
    static func extract(_ url: URL, maxBytes: Int = 64 << 20,
                        wanted: (String) -> Bool) throws -> (names: [String], files: [String: Data]) {
        guard let a = archive_read_new() else { throw ArchiveError.cannotOpen("out of memory") }
        defer { archive_read_free(a) }
        archive_read_support_filter_all(a)
        archive_read_support_format_all(a)
        guard archive_read_open_filename(a, url.path, 1 << 16) == 0 else {
            throw ArchiveError.cannotOpen(archive_error_string(a).map { String(cString: $0) } ?? "unknown error")
        }
        var names: [String] = []
        var files: [String: Data] = [:]
        var entry: OpaquePointer?
        while true {
            let r = archive_read_next_header(a, &entry)
            guard r == 0 || r == -20, let e = entry else { break }      // ARCHIVE_OK or ARCHIVE_WARN
            let name = decodeName(e)
            names.append(name)
            guard wanted(name) else { archive_read_data_skip(a); continue }
            // Stop at the entry's recorded size: Apple's libarchive can return stale bytes past
            // the end of a compressed xar entry.
            let limit = archive_entry_size_is_set(e) != 0 ? min(Int(archive_entry_size(e)), maxBytes) : maxBytes
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1 << 16)
            while data.count < limit {
                let n = buffer.withUnsafeMutableBytes { archive_read_data(a, $0.baseAddress, $0.count) }
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            files[name] = data.prefix(limit)
        }
        return (names, files)
    }

    /// Filename encoding detection.
    ///
    /// Apple's libarchive decodes zip names that lack the UTF-8 flag as CP437. That is right
    /// for old Windows zips, but turns UTF-8 names from older Mac zips ("Grüße") into
    /// "Gr├╝├ƒe", and Shift-JIS/GBK names into nonsense. When a decoded name looks like
    /// mojibake, we re-encode it to CP437 to recover the original bytes and try again.
    private static func decodeName(_ e: OpaquePointer) -> String {
        guard let p = archive_entry_pathname_utf8(e) ?? archive_entry_pathname(e) else { return "?" }
        return repairEncoding(undoubled(String(cString: p)))
    }

    /// Apple's libarchive returns nested xar paths twice ("a.pkg/Boma.pkg/Bom"). Undo that.
    static func undoubled(_ s: String) -> String {
        let chars = Array(s)
        guard chars.count >= 4, chars.count % 2 == 0, s.contains("/") else { return s }
        let half = chars.count / 2
        return chars[..<half] == chars[half...] ? String(chars[..<half]) : s
    }

    private static let cp437 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue)))
    private static let cjkEncodings: [String.Encoding] = [
        .shiftJIS,
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))),
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue))),
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.EUC_KR.rawValue))),
    ]

    static func repairEncoding(_ s: String) -> String {
        let pre = s.precomposedStringWithCanonicalMapping
        guard looksLikeMojibake(pre), let raw = pre.data(using: cp437) else { return s }
        if let utf8 = String(data: raw, encoding: .utf8) { return utf8 }
        for enc in cjkEncodings {
            if let t = String(data: raw, encoding: enc), isCleanCJK(t) { return t }
        }
        return s
    }

    /// Non-ASCII characters that aren't Latin letters (box drawing, Greek, symbols…).
    private static func looksLikeMojibake(_ s: String) -> Bool {
        s.unicodeScalars.contains { v in
            !v.isASCII && !((0xC0...0x24F).contains(v.value) && v.properties.isAlphabetic)
        }
    }

    private static func isCleanCJK(_ s: String) -> Bool {
        let wide = s.unicodeScalars.filter { !$0.isASCII }
        return wide.count >= 2 && wide.allSatisfy { v in
            [0x3000...0x30FF, 0x3400...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF00...0xFFEF].contains { $0.contains(Int(v.value)) }
        }
    }

    static func buildTree(_ items: [Item], rootName: String, showHidden: Bool) -> Entry {
        let root = makeDir(name: rootName, path: "")
        root.children = []
        var dirs: [String: Entry] = ["": root]

        func dir(_ path: String) -> Entry {
            if let d = dirs[path] { return d }
            let parent = dir((path as NSString).deletingLastPathComponent)
            let d = makeDir(name: (path as NSString).lastPathComponent, path: path)
            d.children = []
            parent.children!.append(d)
            dirs[path] = d
            return d
        }

        for item in items {
            var p = item.path
            while p.hasPrefix("./") { p.removeFirst(2) }
            while p.hasPrefix("/") { p.removeFirst() }
            while p.hasSuffix("/") { p.removeLast() }
            if p.isEmpty || p == "." { continue }
            if !showHidden {
                let comps = p.split(separator: "/")
                if comps.contains(where: { $0.hasPrefix(".") || $0 == "__MACOSX" }) { continue }
            }
            if item.isDir {
                dir(p).modified = item.mtime
            } else {
                let parent = dir((p as NSString).deletingLastPathComponent)
                let name = (p as NSString).lastPathComponent
                let type = UTType(filenameExtension: (name as NSString).pathExtension)
                parent.children!.append(Entry(
                    name: name, fileURL: nil, archivePath: p, isDirectory: false, isPackage: false,
                    kind: type?.localizedDescription.map(capitalizedFirst) ?? "Document", utType: type,
                    size: item.size, modified: item.mtime, created: nil))
            }
        }
        computeSizes(root)
        return root
    }

    private static func capitalizedFirst(_ s: String) -> String {
        s.prefix(1).uppercased() + s.dropFirst()
    }

    private static func makeDir(name: String, path: String) -> Entry {
        Entry(name: name, fileURL: nil, archivePath: path, isDirectory: true, isPackage: false,
              kind: "Folder", utType: .folder, size: nil, modified: nil, created: nil)
    }

    @discardableResult
    private static func computeSizes(_ e: Entry) -> Int64 {
        guard let kids = e.children else { return e.size ?? 0 }
        let total = kids.reduce(Int64(0)) { $0 + computeSizes($1) }
        e.size = total
        e.itemCount = kids.count
        return total
    }
}
