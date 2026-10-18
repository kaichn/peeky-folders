import Foundation

/// Reads the file list of an HFS+ ("Mac OS Extended") volume from its catalog B-tree.
/// Follows Apple's TN1150. All numbers are big-endian; dates count seconds from 1904.
final class HFSPlusReader {
    private let disk: PartitionReader
    private let blockSize: UInt64
    private let catalogExtents: [(start: UInt64, count: UInt64)]
    let isHFSX: Bool

    init(_ disk: PartitionReader) throws {
        self.disk = disk
        let vh = Bytes(try disk.read(1024, 512))
        let sig = try vh.string(0, length: 2)
        guard sig == "H+" || sig == "HX" else { throw DiskImageReader.ImageError.noFileSystem("not HFS+") }
        isHFSX = sig == "HX"
        blockSize = UInt64(try vh.u32(40))
        var extents: [(UInt64, UInt64)] = []
        for i in 0..<8 {                                   // catalog file fork: 8 inline extents
            let o = 272 + 16 + i * 8
            let start = UInt64(try vh.u32(o)), count = UInt64(try vh.u32(o + 4))
            if count > 0 { extents.append((start, count)) }
        }
        catalogExtents = extents
        guard blockSize >= 512, !extents.isEmpty else { throw DiskImageReader.ImageError.noFileSystem("empty HFS+ catalog") }
    }

    /// Reads bytes from the catalog file, following its extents.
    private func readCatalog(_ offset: UInt64, _ count: Int) throws -> Data {
        var out = Data(capacity: count)
        var logical = offset
        let end = offset + UInt64(count)
        var extentStart: UInt64 = 0
        for e in catalogExtents {
            let len = e.count * blockSize
            if logical < extentStart + len, logical < end {
                let within = logical - extentStart
                let take = Int(min(end - logical, len - within))
                out.append(try disk.read(e.start * blockSize + within, take))
                logical += UInt64(take)
            }
            extentStart += len
            if logical >= end { break }
        }
        guard out.count == count else { throw DiskImageReader.ImageError.noFileSystem("HFS+ catalog is fragmented") }
        return out
    }

    func items() throws -> ([ArchiveReader.Item], String) {
        let header = Bytes(try readCatalog(0, 512))
        let firstLeaf = try header.u32(14 + 10)
        let nodeSize = Int(try header.u16(14 + 18))
        guard nodeSize >= 512 else { throw DiskImageReader.ImageError.noFileSystem("bad HFS+ catalog") }

        struct Node { var parent: UInt32; var name: String; var isDir: Bool; var size: Int64?; var mtime: Date?; var isLink = false }
        var byID: [UInt32: Node] = [:]
        var volumeName = ""
        var nodeIndex = firstLeaf
        var seen = Set<UInt32>()
        let hfsEpoch: TimeInterval = 2_082_844_800

        while nodeIndex != 0, seen.insert(nodeIndex).inserted {
            let node = Bytes(try readCatalog(UInt64(nodeIndex) * UInt64(nodeSize), nodeSize))
            let next = try node.u32(0)
            let records = Int(try node.u16(10))
            for r in 0..<records {
                let start = Int(try node.u16(nodeSize - 2 * (r + 1)))
                let keyLength = Int(try node.u16(start))
                let parent = try node.u32(start + 2)
                let nameLength = Int(try node.u16(start + 6))
                var units: [UInt16] = []
                for k in 0..<nameLength { units.append(try node.u16(start + 8 + k * 2)) }
                let name = String(decoding: units, as: UTF16.self)
                let rec = start + 2 + keyLength
                let type = try node.u16(rec)
                func date(_ o: Int) -> Date? {
                    guard let v = try? node.u32(rec + o), v > 0 else { return nil }
                    return Date(timeIntervalSince1970: TimeInterval(v) - hfsEpoch)
                }
                switch type {
                case 1:                                           // folder
                    let id = try node.u32(rec + 8)
                    if id == 2 { volumeName = name }
                    byID[id] = Node(parent: parent, name: name, isDir: true, size: nil, mtime: date(16))
                case 2:                                           // file
                    let id = try node.u32(rec + 8)
                    let size = Int64(bitPattern: try node.u64(rec + 88))
                    let isLink = try node.u32(rec + 48) == 0x736C_6E6B           // Finder type "slnk"
                    byID[id] = Node(parent: parent, name: name, isDir: false, size: size, mtime: date(16), isLink: isLink)
                default:
                    break                                         // thread records
                }
            }
            nodeIndex = next
        }

        // Paths from the root folder (ID 2). Skip HFS+ private folders (names start with NUL).
        var paths: [UInt32: String?] = [2: ""]
        func path(_ id: UInt32, depth: Int = 0) -> String? {
            if let p = paths[id] { return p }
            guard depth < 256, let n = byID[id], !n.name.hasPrefix("\u{0}"),
                  let parent = path(n.parent, depth: depth + 1) else { paths[id] = .some(nil); return nil }
            let p = parent.isEmpty ? n.name : parent + "/" + n.name
            paths[id] = p
            return p
        }
        let items = byID.compactMap { id, n -> ArchiveReader.Item? in
            guard id != 2, let p = path(id) else { return nil }
            return ArchiveReader.Item(path: p, isDir: n.isDir, size: n.size, mtime: n.mtime, isLink: n.isLink)
        }
        return (items, volumeName)
    }
}
