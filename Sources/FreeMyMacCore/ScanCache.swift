import Foundation

/// The last scan, saved so the next launch can show it at once and catch up on
/// what changed since, instead of reading the whole disk again.
///
/// A compact binary file: a header, then every node in depth-first order. Only
/// names are stored, since each path is its parent's path plus the name.
public enum ScanCache {
    public struct Header: Sendable, Equatable {
        /// The folder that was scanned. A cache for another folder is ignored.
        public var scanRoot: String
        /// Identifies the volume's change history. If macOS reset that history,
        /// the event ID below means nothing and the cache is ignored.
        public var volumeID: String
        /// Every change after this event is replayed when the cache is loaded.
        public var eventID: UInt64
        public var scannedAt: Date
        /// A scan without Full Disk Access is missing folders, so it isn't reused once access is on.
        public var hadFullDiskAccess: Bool

        public init(scanRoot: String, volumeID: String, eventID: UInt64, scannedAt: Date, hadFullDiskAccess: Bool) {
            self.scanRoot = scanRoot
            self.volumeID = volumeID
            self.eventID = eventID
            self.scannedAt = scannedAt
            self.hadFullDiskAccess = hadFullDiskAccess
        }
    }

    private static let magic: UInt32 = 0x464D_4D43 // "FMMC"
    private static let version: UInt32 = 1

    private enum Flag {
        static let directory: UInt8 = 1
        static let blocked: UInt8 = 2
        static let hasDate: UInt8 = 4
    }

    // MARK: - Writing

    /// Call inside `SharedTree.read` when the tree is shared.
    public static func encode(_ root: FileNode, header: Header) -> Data {
        var out = Writer()
        out.reserve(1 << 20)
        out.u32(magic)
        out.u32(version)
        out.string(header.scanRoot)
        out.string(header.volumeID)
        out.u64(header.eventID)
        out.f64(header.scannedAt.timeIntervalSince1970)
        out.u8(header.hadFullDiskAccess ? 1 : 0)
        out.string(root.path)

        var stack = [root]
        while let node = stack.popLast() {
            var flags: UInt8 = 0
            if node.isDirectory { flags |= Flag.directory }
            if node.isBlocked { flags |= Flag.blocked }
            if node.modified != nil { flags |= Flag.hasDate }
            out.string(node.name)
            out.u8(flags)
            out.i64(node.size)
            out.i64(node.smallSize)
            out.u32(UInt32(clamping: node.smallCount))
            out.i64(Int64(node.modified?.timeIntervalSince1970 ?? 0))
            out.u32(UInt32(node.children.count))
            // Reversed so they come off the stack, and are read back, in order.
            stack.append(contentsOf: node.children.reversed())
        }
        return out.data
    }

    public static func write(_ root: FileNode, header: Header, to path: String) throws {
        let data = encode(root, header: header)
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Reading

    public static func read(from path: String) -> (root: FileNode, header: Header)? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return decode(data)
    }

    public static func decode(_ data: Data) -> (root: FileNode, header: Header)? {
        data.withUnsafeBytes { buffer -> (FileNode, Header)? in
            var input = Reader(buffer: buffer)
            guard input.u32() == magic, input.u32() == version,
                  let scanRoot = input.string(), let volumeID = input.string(),
                  let eventID = input.u64(), let scannedAt = input.f64(), let access = input.u8(),
                  let rootPath = input.string() else { return nil }
            let header = Header(scanRoot: scanRoot, volumeID: volumeID, eventID: eventID,
                                scannedAt: Date(timeIntervalSince1970: scannedAt), hadFullDiskAccess: access == 1)

            func node(path: String?, parent: FileNode?) -> FileNode? {
                guard let name = input.string(), let flags = input.u8(), let size = input.i64(),
                      let smallSize = input.i64(), let smallCount = input.u32(),
                      let modified = input.i64(), let childCount = input.u32() else { return nil }
                let ownPath: String
                if let path {
                    ownPath = path
                } else if let parent {
                    ownPath = parent.path == "/" ? "/" + name : parent.path + "/" + name
                } else {
                    return nil
                }
                let result = FileNode(name: name, path: ownPath, isDirectory: flags & Flag.directory != 0, size: size,
                                      modified: flags & Flag.hasDate != 0 ? Date(timeIntervalSince1970: TimeInterval(modified)) : nil)
                result.isBlocked = flags & Flag.blocked != 0
                result.smallSize = smallSize
                result.smallCount = Int(smallCount)
                result.parent = parent
                // A corrupt count can't make this allocate more than the file holds.
                guard Int(childCount) <= input.remaining else { return nil }
                var children: [FileNode] = []
                children.reserveCapacity(Int(childCount))
                for _ in 0..<childCount {
                    guard let child = node(path: nil, parent: result) else { return nil }
                    children.append(child)
                }
                result.children = children
                return result
            }

            guard let root = node(path: rootPath, parent: nil), input.remaining == 0 else { return nil }
            return (root, header)
        }
    }

    // MARK: - Bytes

    private struct Writer {
        var data = Data()

        mutating func reserve(_ count: Int) { data.reserveCapacity(count) }
        mutating func u8(_ value: UInt8) { data.append(value) }
        mutating func u32(_ value: UInt32) { Swift.withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        mutating func u64(_ value: UInt64) { Swift.withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        mutating func i64(_ value: Int64) { u64(UInt64(bitPattern: value)) }
        mutating func f64(_ value: Double) { u64(value.bitPattern) }
        mutating func string(_ value: String) {
            let bytes = Array(value.utf8)
            u32(UInt32(bytes.count))
            data.append(contentsOf: bytes)
        }
    }

    private struct Reader {
        let buffer: UnsafeRawBufferPointer
        var offset = 0

        var remaining: Int { buffer.count - offset }

        mutating func take<T: FixedWidthInteger>(_: T.Type) -> T? {
            let size = MemoryLayout<T>.size
            guard remaining >= size else { return nil }
            let value = buffer.loadUnaligned(fromByteOffset: offset, as: T.self)
            offset += size
            return T(littleEndian: value)
        }

        mutating func u8() -> UInt8? { take(UInt8.self) }
        mutating func u32() -> UInt32? { take(UInt32.self) }
        mutating func u64() -> UInt64? { take(UInt64.self) }
        mutating func i64() -> Int64? { u64().map { Int64(bitPattern: $0) } }
        mutating func f64() -> Double? { u64().map { Double(bitPattern: $0) } }
        mutating func string() -> String? {
            guard let count = u32().map(Int.init), remaining >= count else { return nil }
            let slice = UnsafeRawBufferPointer(rebasing: buffer[offset..<offset + count])
            offset += count
            return String(decoding: slice, as: UTF8.self)
        }
    }
}
