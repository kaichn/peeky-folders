import Compression
import Foundation

/// Lists the files on a disk image (.dmg) without mounting it.
///
/// A UDIF image ends with a 512-byte "koly" trailer that points to an XML property list.
/// Its "blkx" entries describe each partition as a run of chunks, each stored raw,
/// zero-filled or compressed (zlib, bzip2, LZFSE or LZMA). `PartitionReader` turns that back
/// into a readable byte range, decompressing only the chunks a read touches, and the
/// HFS+ or APFS reader walks the file system's catalog from there.
enum DiskImageReader {
    enum ImageError: LocalizedError {
        case encrypted, notUDIF, noFileSystem(String), unsupportedChunk(UInt32)
        var errorDescription: String? {
            switch self {
            case .encrypted: return "This disk image is encrypted, so its contents can't be shown without the password."
            case .notUDIF: return "This disk image format isn't supported."
            case .noFileSystem(let what): return "No readable file system found (\(what))."
            case .unsupportedChunk: return "This disk image uses a compression format that isn't supported."
            }
        }
    }

    static func isDiskImage(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "dmg"
    }

    static func read(_ url: URL, showHidden: Bool) throws -> (Entry, [Detail]) {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let fileSize = try file.seekToEnd()

        // Encrypted images start with their own header instead of plain data.
        try file.seek(toOffset: 0)
        let magic = String(decoding: try file.read(upToCount: 8) ?? Data(), as: UTF8.self)
        if magic == "encrcdsa" || magic == "cdsaencr" { throw ImageError.encrypted }

        guard fileSize > 512 else { throw ImageError.notUDIF }
        try file.seek(toOffset: fileSize - 512)
        let koly = Bytes(try file.read(upToCount: 512) ?? Data())
        guard (try? koly.string(0, length: 4)) == "koly" else { throw ImageError.notUDIF }
        let dataForkOffset = try koly.u64(24)
        let xmlOffset = try koly.u64(216)
        let xmlLength = try koly.u64(224)
        guard xmlLength > 0, xmlLength < 64 << 20 else { throw ImageError.notUDIF }
        try file.seek(toOffset: xmlOffset)
        let xml = try file.read(upToCount: Int(xmlLength)) ?? Data()
        guard let plist = try PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any],
              let fork = plist["resource-fork"] as? [String: Any],
              let blkx = fork["blkx"] as? [[String: Any]] else { throw ImageError.notUDIF }

        // Try each partition until one holds a file system we can read.
        var compression: String?
        var tried: [String] = []
        for part in blkx {
            guard let data = part["Data"] as? Data else { continue }
            let name = (part["CFName"] as? String) ?? (part["Name"] as? String) ?? "?"
            guard let reader = try? PartitionReader(file: file, table: data, dataForkOffset: dataForkOffset),
                  reader.length >= 4096 else { continue }
            compression = compression ?? reader.compressionName
            tried.append(name)
            if let hfs = try? HFSPlusReader(reader), let (items, volume) = try? hfs.items() {
                return finish(url, items, volume: volume, fs: hfs.isHFSX ? "Mac OS Extended (case-sensitive)" : "Mac OS Extended",
                              compression: reader.compressionName, showHidden: showHidden)
            }
            if let apfs = try? APFSReader(reader) {
                let (items, volume) = try apfs.items()
                return finish(url, items, volume: volume, fs: "APFS",
                              compression: reader.compressionName, showHidden: showHidden)
            }
        }
        throw ImageError.noFileSystem(tried.isEmpty ? "no partitions" : tried.joined(separator: ", "))
    }

    private static func finish(_ url: URL, _ items: [ArchiveReader.Item], volume: String, fs: String,
                               compression: String?, showHidden: Bool) -> (Entry, [Detail]) {
        let root = ArchiveReader.buildTree(items, rootName: url.lastPathComponent, showHidden: showHidden)
        var details: [Detail] = []
        if !volume.isEmpty { details.append(Detail(text: "Volume “\(volume)”")) }
        details.append(Detail(text: fs))
        if let compression { details.append(Detail(text: compression)) }
        details.append(BundleInspector.signature(url, unsignedIsWarning: false))
        return (root, details)
    }
}

/// Random access to one partition of a UDIF image, decompressing chunks on demand.
final class PartitionReader {
    private struct Chunk {
        let type: UInt32
        let start: UInt64          // byte offset within the partition
        let length: UInt64         // decompressed length
        let fileOffset: UInt64
        let fileLength: UInt64
    }

    private let file: FileHandle
    private let chunks: [Chunk]
    let length: UInt64
    private var cache: [Int: Data] = [:]
    private var cacheOrder: [Int] = []

    init(file: FileHandle, table: Data, dataForkOffset: UInt64) throws {
        self.file = file
        let t = Bytes(table)
        guard (try t.string(0, length: 4)) == "mish" else { throw DiskImageReader.ImageError.notUDIF }
        let sectorCount = try t.u64(16)
        let dataOffset = try t.u64(24)
        let count = Int(try t.u32(200))
        var chunks: [Chunk] = []
        for i in 0..<count {
            let o = 204 + i * 40
            let type = try t.u32(o)
            if type == 0xFFFF_FFFF || type == 0x7FFF_FFFE { continue }        // end marker, comment
            chunks.append(Chunk(type: type, start: try t.u64(o + 8) * 512, length: try t.u64(o + 16) * 512,
                                fileOffset: dataForkOffset + dataOffset + (try t.u64(o + 24)),
                                fileLength: try t.u64(o + 32)))
        }
        self.chunks = chunks
        self.length = sectorCount * 512
    }

    /// The compression most chunks use, for the header ("Compressed (LZFSE)").
    var compressionName: String? {
        var counts: [UInt32: Int] = [:]
        for c in chunks where c.type & 0x8000_0000 != 0 { counts[c.type, default: 0] += 1 }
        guard let top = counts.max(by: { $0.value < $1.value })?.key else { return nil }
        switch top {
        case 0x8000_0005: return "Compressed (zlib)"
        case 0x8000_0006: return "Compressed (bzip2)"
        case 0x8000_0007: return "Compressed (LZFSE)"
        case 0x8000_0008: return "Compressed (LZMA)"
        case 0x8000_0004: return "Compressed (ADC)"
        default: return "Compressed"
        }
    }

    func read(_ offset: UInt64, _ count: Int) throws -> Data {
        var out = Data(capacity: count)
        var pos = offset
        let end = offset + UInt64(count)
        while pos < end {
            guard let i = chunkIndex(containing: pos) else {               // past the end: zeros
                out.append(Data(count: Int(end - pos)))
                break
            }
            let chunk = chunks[i]
            let data = try decompressed(i)
            let from = Int(pos - chunk.start)
            let take = min(Int(end - pos), data.count - from)
            guard take > 0 else { throw DiskImageReader.ImageError.notUDIF }
            out.append(data[data.startIndex + from ..< data.startIndex + from + take])
            pos += UInt64(take)
        }
        return out
    }

    private func chunkIndex(containing pos: UInt64) -> Int? {
        var lo = 0, hi = chunks.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let c = chunks[mid]
            if pos < c.start { hi = mid - 1 } else if pos >= c.start + c.length { lo = mid + 1 } else { return mid }
        }
        return nil
    }

    private func decompressed(_ i: Int) throws -> Data {
        if let d = cache[i] { return d }
        let c = chunks[i]
        let size = Int(c.length)
        let data: Data
        switch c.type {
        case 0x0000_0000, 0x0000_0002:                                       // zero-fill, ignored
            data = Data(count: size)
        default:
            try file.seek(toOffset: c.fileOffset)
            let raw = try file.read(upToCount: Int(c.fileLength)) ?? Data()
            switch c.type {
            case 0x0000_0001: data = raw
            case 0x8000_0005: data = try Self.decode(raw.dropFirst(2), size, COMPRESSION_ZLIB)   // skip zlib header
            case 0x8000_0007: data = try Self.decode(raw, size, COMPRESSION_LZFSE)
            case 0x8000_0008: data = try Self.decode(raw, size, COMPRESSION_LZMA)
            case 0x8000_0006: data = try Self.bunzip(raw, size)
            default: throw DiskImageReader.ImageError.unsupportedChunk(c.type)
            }
        }
        cache[i] = data
        cacheOrder.append(i)
        if cacheOrder.count > 24 { cache[cacheOrder.removeFirst()] = nil }
        return data
    }

    private static func decode(_ src: Data, _ size: Int, _ algorithm: compression_algorithm) throws -> Data {
        var out = Data(count: size)
        let n = out.withUnsafeMutableBytes { dst in
            src.withUnsafeBytes { s in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, size,
                                          s.bindMemory(to: UInt8.self).baseAddress!, src.count, nil, algorithm)
            }
        }
        guard n > 0 else { throw DiskImageReader.ImageError.notUDIF }
        if n < size { out.replaceSubrange(n..<size, with: Data(count: size - n)) }
        return out
    }

    private static func bunzip(_ src: Data, _ size: Int) throws -> Data {
        var out = Data(count: size)
        var destLen = UInt32(size)
        var input = src
        let r = out.withUnsafeMutableBytes { dst in
            input.withUnsafeMutableBytes { s in
                BZ2_bzBuffToBuffDecompress(dst.bindMemory(to: CChar.self).baseAddress!, &destLen,
                                           s.bindMemory(to: CChar.self).baseAddress!, UInt32(src.count), 0, 0)
            }
        }
        guard r == 0 else { throw DiskImageReader.ImageError.notUDIF }
        return out
    }
}
