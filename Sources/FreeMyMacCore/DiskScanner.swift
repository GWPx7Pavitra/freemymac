import Foundation

public final class FileNode: Identifiable {
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let modified: Date?
    public fileprivate(set) var size: Int64
    public fileprivate(set) var children: [FileNode] = []
    /// Items too small to keep individually, rolled into one figure to keep memory flat.
    public fileprivate(set) var smallSize: Int64 = 0
    public fileprivate(set) var smallCount = 0
    public fileprivate(set) var isBlocked = false
    public fileprivate(set) weak var parent: FileNode?

    public var id: String { path }

    init(name: String, path: String, isDirectory: Bool, size: Int64, modified: Date?) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
    }

    public func child(named name: String) -> FileNode? {
        children.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    public func node(at path: String) -> FileNode? {
        if path == self.path { return self }
        let base = self.path == "/" ? "/" : self.path + "/"
        guard path.hasPrefix(base) else { return nil }
        var current = self
        for part in path.dropFirst(base.count).split(separator: "/") {
            guard let next = current.child(named: String(part)) else { return nil }
            current = next
        }
        return current
    }

    /// Takes this node out of the tree and shrinks every ancestor to match.
    public func detach() {
        var ancestor = parent
        while let node = ancestor {
            node.size -= size
            ancestor = node.parent
        }
        parent?.children.removeAll { $0 === self }
        parent = nil
    }

    /// Folders that hold their own weight rather than just wrapping one big child.
    /// These are the answers to "what's actually using my disk?".
    public func heaviest(limit: Int, minimum: Int64) -> [FileNode] {
        var found: [FileNode] = []
        func visit(_ node: FileNode) {
            guard node.size >= minimum else { return }
            let dominated = node.children.first.map { Double($0.size) >= Double(node.size) * 0.6 } ?? false
            if node.isDirectory, !node.children.isEmpty, dominated || node.parent == nil || node.path.split(separator: "/").count < 3 {
                node.children.forEach(visit)
            } else {
                found.append(node)
            }
        }
        visit(self)
        return Array(found.sorted { $0.size > $1.size }.prefix(limit))
    }
}

public struct LargeFile: Identifiable, Sendable {
    public let path: String
    public let name: String
    public let size: Int64
    public let modified: Date?
    public var id: String { path }
}

public final class ScanProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var _files = 0
    private var _bytes: Int64 = 0
    private var _cancelled = false

    public init() {}

    public var files: Int { lock.withLock { _files } }
    public var bytes: Int64 { lock.withLock { _bytes } }
    public var isCancelled: Bool { lock.withLock { _cancelled } }
    public func cancel() { lock.withLock { _cancelled = true } }

    fileprivate func add(files: Int, bytes: Int64) {
        lock.withLock {
            _files += files
            _bytes += bytes
        }
    }
}

public struct ScanResult {
    public let root: FileNode
    public let largeFiles: [LargeFile]
    public let blocked: [String]
    public let fileCount: Int
    public let duration: TimeInterval
}

public enum DiskScanner {
    public struct Options: Sendable {
        public var keepThreshold: Int64 = 1 << 20
        public var largeFileThreshold: Int64 = 100 << 20
        public var parallelDepth = 3
        public init() {}
    }

    public static func scan(root: String, options: Options = Options(), progress: ScanProgress = ScanProgress()) -> ScanResult {
        let started = Date()
        let walker = Walker(options: options, progress: progress)
        let node = walker.scan(root: root)
        return ScanResult(
            root: node,
            largeFiles: walker.large.sorted { $0.size > $1.size },
            blocked: walker.blocked.sorted(),
            fileCount: progress.files,
            duration: Date().timeIntervalSince(started)
        )
    }

    /// Bytes actually occupied on disk at `path`. A symlink counts as itself.
    public static func measure(_ path: String) -> Int64 {
        var options = Options()
        options.keepThreshold = .max
        options.largeFileThreshold = .max
        options.parallelDepth = 0
        return Walker(options: options, progress: ScanProgress()).scan(root: path).size
    }
}

private final class Walker: @unchecked Sendable {
    let options: DiskScanner.Options
    let progress: ScanProgress
    private let lock = NSLock()
    private var seenLinks = Set<HardLink>()
    private(set) var large: [LargeFile] = []
    private(set) var blocked: [String] = []
    private var rootDevice: dev_t = 0

    struct HardLink: Hashable {
        let device: dev_t
        let inode: ino_t
    }

    init(options: DiskScanner.Options, progress: ScanProgress) {
        self.options = options
        self.progress = progress
    }

    func scan(root: String) -> FileNode {
        var st = stat()
        let display = displayPath(root)
        let name = (display as NSString).lastPathComponent
        guard lstat(root, &st) == 0 else {
            return FileNode(name: name, path: display, isDirectory: false, size: 0, modified: nil)
        }
        rootDevice = st.st_dev
        guard (st.st_mode & S_IFMT) == S_IFDIR else {
            return FileNode(name: name, path: display, isDirectory: false,
                            size: Int64(st.st_blocks) * 512, modified: Self.date(st))
        }
        return walk(path: root, name: name, ownBlocks: Int64(st.st_blocks) * 512, modified: Self.date(st), depth: 0)
    }

    private func walk(path: String, name: String, ownBlocks: Int64, modified: Date?, depth: Int) -> FileNode {
        let display = displayPath(path)
        let node = FileNode(name: name, path: display, isDirectory: true, size: ownBlocks, modified: modified)
        if progress.isCancelled { return node }

        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0, let dir = fdopendir(fd) else {
            let code = errno
            if fd >= 0 { close(fd) }
            if code == EPERM || code == EACCES {
                node.isBlocked = true
                lock.withLock { if blocked.count < 5000 { blocked.append(display) } }
            }
            return node
        }

        struct Sub {
            let name: String
            let blocks: Int64
            let modified: Date?
        }
        var subdirs: [Sub] = []
        var keptFiles: [FileNode] = []
        var total = ownBlocks
        var smallSize: Int64 = 0
        var smallCount = 0
        var fileCount = 0
        var fileBytes: Int64 = 0
        let separator = path.hasSuffix("/") ? "" : "/"

        while let entry = readdir(dir) {
            let length = Int(entry.pointee.d_namlen)
            var st = stat()
            let (entryName, status): (String, Int32) = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: length + 1) { cName in
                    if cName[0] == 46, length == 1 || (length == 2 && cName[1] == 46) { return ("", -1) }
                    let rc = fstatat(fd, cName, &st, AT_SYMLINK_NOFOLLOW)
                    return (String(cString: cName), rc)
                }
            }
            guard status == 0 else { continue }
            let kind = st.st_mode & S_IFMT
            let blocks = Int64(st.st_blocks) * 512

            if kind == S_IFDIR {
                if st.st_dev == rootDevice {
                    subdirs.append(Sub(name: entryName, blocks: blocks, modified: Self.date(st)))
                }
                continue
            }
            // A file with several hard links occupies its blocks once, however
            // many names point at it. pnpm stores are full of these.
            if kind == S_IFREG, st.st_nlink > 1 {
                let link = HardLink(device: st.st_dev, inode: st.st_ino)
                let isNew = lock.withLock { seenLinks.insert(link).inserted }
                if !isNew { continue }
            }
            total += blocks
            fileCount += 1
            fileBytes += blocks
            if blocks >= options.keepThreshold {
                let childPath = display == "/" ? "/" + entryName : display + "/" + entryName
                let modifiedDate = Self.date(st)
                keptFiles.append(FileNode(name: entryName, path: childPath, isDirectory: false, size: blocks, modified: modifiedDate))
                if blocks >= options.largeFileThreshold {
                    let file = LargeFile(path: childPath, name: entryName, size: blocks, modified: modifiedDate)
                    lock.withLock { large.append(file) }
                }
            } else {
                smallSize += blocks
                smallCount += 1
            }
        }
        closedir(dir)
        progress.add(files: fileCount, bytes: fileBytes)

        var results = [FileNode?](repeating: nil, count: subdirs.count)
        func scanSub(_ index: Int) -> FileNode {
            let sub = subdirs[index]
            return walk(path: path + separator + sub.name, name: sub.name, ownBlocks: sub.blocks, modified: sub.modified, depth: depth + 1)
        }
        if depth < options.parallelDepth, subdirs.count > 1 {
            let resultsLock = NSLock()
            DispatchQueue.concurrentPerform(iterations: subdirs.count) { index in
                let result = scanSub(index)
                resultsLock.withLock { results[index] = result }
            }
        } else {
            for index in subdirs.indices { results[index] = scanSub(index) }
        }

        var kept = keptFiles
        for case let child? in results {
            total += child.size
            if child.size >= options.keepThreshold || child.isBlocked {
                kept.append(child)
            } else {
                smallSize += child.size
                smallCount += 1
            }
        }
        kept.sort { $0.size > $1.size }
        for child in kept { child.parent = node }
        node.children = kept
        node.smallSize = smallSize
        node.smallCount = smallCount
        node.size = total
        return node
    }

    private static func date(_ st: stat) -> Date? {
        Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
    }
}
