import Foundation

/// Reads the file list of the first volume in an APFS container, following Apple's
/// "Apple File System Reference". All numbers are little-endian.
///
/// Path: container superblock (newest checkpoint) -> container object map -> volume
/// superblock -> volume object map -> file-system B-tree. Directory records give names and
/// parent folders; inode records give sizes and dates.
final class APFSReader {
    private let disk: PartitionReader
    private let blockSize: UInt64
    private let superblock: Bytes

    init(_ disk: PartitionReader) throws {
        self.disk = disk
        let block0 = Bytes(try disk.read(0, 4096))
        guard try block0.le32(32) == 0x4253_584E else {                     // "NXSB"
            throw DiskImageReader.ImageError.noFileSystem("not APFS")
        }
        blockSize = UInt64(try block0.le32(36))
        guard blockSize >= 4096, blockSize <= 65536 else { throw DiskImageReader.ImageError.noFileSystem("bad APFS block size") }

        // The newest valid superblock lives in the checkpoint descriptor area.
        var best = block0
        var bestXID = try block0.le64(16)
        let descBase = try block0.le64(112)
        let descBlocks = UInt64(try block0.le32(104) & 0x7FFF_FFFF)
        if descBlocks < 4096 {
            for b in 0..<descBlocks {
                guard let blk = try? Bytes(disk.read((descBase + b) * blockSize, Int(blockSize))),
                      (try? blk.le32(24)) .map({ $0 & 0xFFFF == 1 }) == true,       // OBJECT_TYPE_NX_SUPERBLOCK
                      (try? blk.le32(32)) == 0x4253_584E,
                      let xid = try? blk.le64(16), xid > bestXID else { continue }
                best = blk
                bestXID = xid
            }
        }
        superblock = best
    }

    private func block(_ paddr: UInt64) throws -> Bytes {
        Bytes(try disk.read(paddr * blockSize, Int(blockSize)))
    }

    /// Walks a B-tree and calls `visit(key, value)` for every leaf record.
    /// `child` maps a child pointer to a physical block (identity for physical trees,
    /// an object-map lookup for virtual ones).
    private func walk(_ paddr: UInt64, child: (UInt64) -> UInt64?, depth: Int = 0,
                      visit: (Data, Data) throws -> Void) throws {
        guard depth < 16 else { return }
        let node = try block(paddr)
        let flags = try node.le16(32)
        let level = try node.le16(34)
        let nkeys = Int(try node.le32(36))
        let tocOff = Int(try node.le16(40)), tocLen = Int(try node.le16(42))
        let isRoot = flags & 1 != 0, isFixed = flags & 4 != 0
        let keyStart = 56 + tocOff + tocLen
        let valEnd = Int(blockSize) - (isRoot ? 40 : 0)                     // root nodes end with btree_info
        let data = node.data
        for i in 0..<min(nkeys, 4096) {
            let k: (off: Int, len: Int), v: (off: Int, len: Int)
            if isFixed {
                let e = 56 + tocOff + i * 4
                k = (Int(try node.le16(e)), 16)
                v = (Int(try node.le16(e + 2)), level == 0 ? 16 : 8)
            } else {
                let e = 56 + tocOff + i * 8
                k = (Int(try node.le16(e)), Int(try node.le16(e + 2)))
                v = (Int(try node.le16(e + 4)), Int(try node.le16(e + 6)))
            }
            let ks = keyStart + k.off, vs = valEnd - v.off
            guard ks >= 0, ks + k.len <= data.count, vs >= 0, vs + v.len <= data.count, v.off != 0xFFFF else { continue }
            let key = data.subdata(in: ks..<ks + k.len)
            let val = data.subdata(in: vs..<vs + v.len)
            if level == 0 {
                try visit(key, val)
            } else if let next = child(Bytes(val).le64OrNil(0) ?? 0) {
                try walk(next, child: child, depth: depth + 1, visit: visit)
            }
        }
    }

    /// Reads a whole object map into oid -> physical address (newest version of each object).
    private func objectMap(_ omapPaddr: UInt64) throws -> [UInt64: UInt64] {
        let omap = try block(omapPaddr)
        let tree = try omap.le64(48)
        var map: [UInt64: (xid: UInt64, paddr: UInt64)] = [:]
        try walk(tree, child: { $0 }) { key, val in
            let k = Bytes(key), v = Bytes(val)
            let oid = try k.le64(0), xid = try k.le64(8), paddr = try v.le64(8)
            if map[oid].map({ xid > $0.xid }) ?? true { map[oid] = (xid, paddr) }
        }
        return map.mapValues(\.paddr)
    }

    func items() throws -> ([ArchiveReader.Item], String) {
        let containerMap = try objectMap(try superblock.le64(160))
        guard let volumeOID = try? superblock.le64(184), volumeOID != 0,
              let volumePaddr = containerMap[volumeOID] else {
            throw DiskImageReader.ImageError.noFileSystem("APFS container has no volume")
        }
        let volume = try block(volumePaddr)
        guard try volume.le32(32) == 0x4253_5041 else {                       // "APSB"
            throw DiskImageReader.ImageError.noFileSystem("bad APFS volume")
        }
        if try volume.le64(264) & 1 == 0 { throw DiskImageReader.ImageError.encrypted }   // APFS_FS_UNENCRYPTED unset
        let volumeName = (try? volume.cString(704)) ?? ""
        let volumeMap = try objectMap(try volume.le64(128))
        guard let rootPaddr = volumeMap[try volume.le64(136)] else {
            throw DiskImageReader.ImageError.noFileSystem("APFS file tree not found")
        }

        struct Rec { var parent: UInt64; var name: String; var isDir: Bool; var isLink: Bool }
        var dirs: [UInt64: Rec] = [:]                // file_id -> where it lives
        var sizes: [UInt64: Int64] = [:]
        var mtimes: [UInt64: Date] = [:]

        try walk(rootPaddr, child: { volumeMap[$0] }) { key, val in
            let k = Bytes(key), v = Bytes(val)
            let header = try k.le64(0)
            let objID = header & 0x0FFF_FFFF_FFFF_FFFF
            switch header >> 60 {
            case 9:                                                             // APFS_TYPE_DIR_REC
                let nameLen = Int(try k.le32(8) & 0x3FF)
                let name = String(decoding: key.subdata(in: 12..<min(12 + nameLen, key.count)), as: UTF8.self)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\u{0}"))
                let fileID = try v.le64(0)
                let type = try v.le16(16) & 0x000F
                dirs[fileID] = Rec(parent: objID, name: name, isDir: type == 4, isLink: type == 10)
            case 3:                                                             // APFS_TYPE_INODE
                mtimes[objID] = Date(timeIntervalSince1970: TimeInterval(try v.le64(24)) / 1e9)
                if let size = Self.inodeSize(v, val.count) { sizes[objID] = size }
            default:
                break
            }
        }

        // Paths from the root folder (inode 2).
        var paths: [UInt64: String?] = [2: ""]
        func path(_ id: UInt64, depth: Int = 0) -> String? {
            if let p = paths[id] { return p }
            guard depth < 256, let r = dirs[id], let parent = path(r.parent, depth: depth + 1) else {
                paths[id] = .some(nil); return nil
            }
            let p = parent.isEmpty ? r.name : parent + "/" + r.name
            paths[id] = p
            return p
        }
        let items = dirs.compactMap { id, r -> ArchiveReader.Item? in
            guard let p = path(id) else { return nil }
            return ArchiveReader.Item(path: p, isDir: r.isDir, size: r.isDir ? nil : sizes[id], mtime: mtimes[id], isLink: r.isLink)
        }
        return (items, volumeName)
    }

    /// File size from the inode's data-stream extended field, or its uncompressed size.
    private static func inodeSize(_ v: Bytes, _ length: Int) -> Int64? {
        guard length > 92, let count = try? v.le16(92) else { return nil }
        var dataStart = 96 + Int(count) * 4
        for i in 0..<Int(count) {
            guard let type = try? v.u8(96 + i * 4), let size = try? v.le16(96 + i * 4 + 2) else { return nil }
            if type == 8, let s = try? v.le64(dataStart) { return Int64(bitPattern: s) }   // INO_EXT_TYPE_DSTREAM
            dataStart += (Int(size) + 7) & ~7
        }
        let flags = (try? v.le64(48)) ?? 0
        if flags & 0x40000 != 0, let s = try? v.le64(84) { return Int64(bitPattern: s) }  // HAS_UNCOMPRESSED_SIZE
        return nil
    }
}

extension Bytes {
    func le16(_ o: Int) throws -> UInt16 { (try u16(o)).byteSwapped }
    func le32(_ o: Int) throws -> UInt32 { (try u32(o)).byteSwapped }
    func le64(_ o: Int) throws -> UInt64 { (try u64(o)).byteSwapped }
    func le64OrNil(_ o: Int) -> UInt64? { try? le64(o) }
}
