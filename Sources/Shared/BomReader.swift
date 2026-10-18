import Foundation

/// Reads the file list from a "Bill of Materials" (Bom), the manifest inside every installer
/// package. It records each installed path with its type, size and date, so a package can be
/// listed without unpacking its payload. All numbers are big-endian.
///
/// Layout (as documented by the open-source bomutils project):
///   header  "BOMStore", version, block count, index offset/length, vars offset/length
///   index   count, then (address, length) per block
///   vars    count, then (block index, name length, name); "Paths" is the file tree
///   tree    "tree", version, root block, block size, path count
///   paths   isLeaf, count, forward, backward, then (index0, index1) per entry;
///           index0 -> (id, info block), index1 -> (parent id, C-string name)
///   info    type (1 file, 2 dir, 3 link), arch, mode, uid, gid, mtime, size, …
enum BomReader {
    enum BomError: LocalizedError {
        case notABom
        var errorDescription: String? { "The package's file list (Bom) couldn't be read." }
    }

    static func items(_ data: Data) throws -> [ArchiveReader.Item] {
        let bom = Bytes(data)
        guard data.count > 32, String(decoding: data.prefix(8), as: UTF8.self) == "BOMStore" else {
            throw BomError.notABom
        }
        let indexOffset = Int(try bom.u32(16))
        let varsOffset = Int(try bom.u32(24))

        // Block table: block i lives at (address, length).
        let blockCount = try bom.u32(indexOffset)
        func block(_ i: UInt32) throws -> Int {
            guard i < blockCount else { throw BomError.notABom }
            return Int(try bom.u32(indexOffset + 4 + Int(i) * 8))
        }

        // Find the "Paths" variable.
        var pathsBlock: UInt32?
        var p = varsOffset + 4
        for _ in 0..<(try bom.u32(varsOffset)) {
            let index = try bom.u32(p)
            let len = Int(try bom.u8(p + 4))
            let name = try bom.string(p + 5, length: len)
            if name == "Paths" { pathsBlock = index }
            p += 5 + len
        }
        guard let pathsBlock else { throw BomError.notABom }

        // tree header -> root paths block; walk down to the first leaf.
        let tree = try block(pathsBlock)
        guard try bom.string(tree, length: 4) == "tree" else { throw BomError.notABom }
        var node = try block(try bom.u32(tree + 8))
        var guardCount = 0
        while try bom.u16(node) == 0 {                       // not a leaf: follow the first child
            node = try block(try bom.u32(node + 12))
            guardCount += 1
            if guardCount > 64 { throw BomError.notABom }
        }

        struct Raw { var parent: UInt32; var name: String; var isDir: Bool; var size: Int64?; var mtime: Date?; var isLink: Bool }
        var byID: [UInt32: Raw] = [:]
        var order: [UInt32] = []
        var visited = Set<Int>()
        while visited.insert(node).inserted {
            let count = Int(try bom.u16(node + 2))
            let forward = try bom.u32(node + 4)
            for k in 0..<count {
                let entry = node + 12 + k * 8
                let info1 = try block(try bom.u32(entry))
                let file = try block(try bom.u32(entry + 4))
                let id = try bom.u32(info1)
                let info2 = try block(try bom.u32(info1 + 4))
                let type = try bom.u8(info2)
                let mtime = try bom.u32(info2 + 14)
                let size = try bom.u32(info2 + 18)
                let parent = try bom.u32(file)
                let name = try bom.cString(file + 4)
                byID[id] = Raw(parent: parent, name: name, isDir: type == 2,
                               size: type == 1 ? Int64(size) : nil,
                               mtime: mtime > 0 ? Date(timeIntervalSince1970: TimeInterval(mtime)) : nil,
                               isLink: type == 3)
                order.append(id)
            }
            if forward == 0 { break }
            node = try block(forward)
        }

        // Rebuild full paths from the parent links.
        var paths: [UInt32: String] = [:]
        func path(_ id: UInt32, depth: Int = 0) -> String {
            if let p = paths[id] { return p }
            guard let raw = byID[id], depth < 256 else { return "" }
            let p = raw.parent == 0 ? raw.name : path(raw.parent, depth: depth + 1) + "/" + raw.name
            paths[id] = p
            return p
        }
        return order.compactMap { id in
            guard let raw = byID[id] else { return nil }
            return ArchiveReader.Item(path: path(id), isDir: raw.isDir, size: raw.size, mtime: raw.mtime, isLink: raw.isLink)
        }
    }
}

/// Bounds-checked big-endian reads over a Data buffer.
struct Bytes {
    struct OutOfRange: Error {}
    let data: Data
    init(_ data: Data) { self.data = data }

    private func check(_ offset: Int, _ n: Int) throws {
        guard offset >= 0, offset + n <= data.count else { throw OutOfRange() }
    }
    func u8(_ o: Int) throws -> UInt8 { try check(o, 1); return data[data.startIndex + o] }
    func u16(_ o: Int) throws -> UInt16 {
        try check(o, 2)
        return data.withUnsafeBytes { UInt16(bigEndian: $0.loadUnaligned(fromByteOffset: o, as: UInt16.self)) }
    }
    func u32(_ o: Int) throws -> UInt32 {
        try check(o, 4)
        return data.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: o, as: UInt32.self)) }
    }
    func u64(_ o: Int) throws -> UInt64 {
        try check(o, 8)
        return data.withUnsafeBytes { UInt64(bigEndian: $0.loadUnaligned(fromByteOffset: o, as: UInt64.self)) }
    }
    func string(_ o: Int, length: Int) throws -> String {
        try check(o, length)
        return String(decoding: data[(data.startIndex + o)..<(data.startIndex + o + length)], as: UTF8.self)
    }
    func cString(_ o: Int) throws -> String {
        try check(o, 1)
        let start = data.startIndex + o
        let end = data[start...].firstIndex(of: 0) ?? data.endIndex
        return String(decoding: data[start..<end], as: UTF8.self)
    }
}
