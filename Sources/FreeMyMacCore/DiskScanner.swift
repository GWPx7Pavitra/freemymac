import Foundation

public final class FileNode: Identifiable {
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let modified: Date?
    public internal(set) var size: Int64
    public internal(set) var children: [FileNode] = []
    /// Items too small to keep individually, rolled into one figure to keep memory flat.
    public internal(set) var smallSize: Int64 = 0
    public internal(set) var smallCount = 0
    public internal(set) var isBlocked = false
    public internal(set) weak var parent: FileNode?

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

extension DiskScanner {
    public struct Summary: Sendable {
        public let largeFiles: [LargeFile]
        public let blocked: [String]
    }

    /// The large files and unreadable folders in a tree, read from the tree
    /// itself, so it stays right as the tree is updated piece by piece.
    public static func summarize(_ root: FileNode, largeFileThreshold: Int64 = Options().largeFileThreshold) -> Summary {
        var large: [LargeFile] = []
        var blocked: [String] = []
        var stack = [root]
        while let node = stack.popLast() {
            if node.isDirectory {
                if node.isBlocked, blocked.count < 5000 { blocked.append(node.path) }
                stack.append(contentsOf: node.children)
            } else if node.size >= largeFileThreshold {
                large.append(LargeFile(path: node.path, name: node.name, size: node.size, modified: node.modified))
            }
        }
        return Summary(largeFiles: large.sorted { $0.size > $1.size }, blocked: blocked.sorted())
    }
}

/// The scanned tree, shared by the window and background work. The window
/// reads it on the main thread without waiting. Every change happens on the
/// main thread inside `write`, and any other thread reads inside `read`, so
/// the two can never overlap.
public final class SharedTree: @unchecked Sendable {
    public let root: FileNode
    private let lock: UnsafeMutablePointer<pthread_rwlock_t>

    public init(root: FileNode) {
        self.root = root
        lock = .allocate(capacity: 1)
        pthread_rwlock_init(lock, nil)
    }

    deinit {
        pthread_rwlock_destroy(lock)
        lock.deallocate()
    }

    public func read<T>(_ body: (FileNode) throws -> T) rethrows -> T {
        pthread_rwlock_rdlock(lock)
        defer { pthread_rwlock_unlock(lock) }
        return try body(root)
    }

    public func write<T>(_ body: (FileNode) throws -> T) rethrows -> T {
        pthread_rwlock_wrlock(lock)
        defer { pthread_rwlock_unlock(lock) }
        return try body(root)
    }

    /// The measured size of `path`, if the tree holds it. Items under 1 MiB are
    /// folded into their folder's total, so those come back nil.
    public func size(of path: String) -> Int64? {
        read { root in
            guard let node = root.node(at: path), !node.isBlocked else { return nil }
            return node.size
        }
    }

    /// Subfolders of `path` the tree holds, which are all those of 1 MiB or more.
    public func folders(in path: String) -> [String]? {
        read { root in
            root.node(at: path)?.children.filter { $0.isDirectory && !$0.isBlocked }.map(\.path)
        }
    }
}

/// Walks folders with plain syscalls. One walker is one pass: it remembers hard
/// links it has already counted, so a file with several names is counted once.
final class Walker: @unchecked Sendable {
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

    struct Subfolder {
        let name: String
        let blocks: Int64
        let modified: Date?
    }

    /// One folder's own entries: its files, counted, and its subfolders, not yet walked.
    struct Entries {
        var subfolders: [Subfolder] = []
        var keptFiles: [FileNode] = []
        var fileBlocks: Int64 = 0
        var smallSize: Int64 = 0
        var smallCount = 0
    }

    enum Opened {
        case listed(Entries)
        case blocked
        case gone
    }

    init(options: DiskScanner.Options, progress: ScanProgress, device: dev_t = 0) {
        self.options = options
        self.progress = progress
        self.rootDevice = device
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

    /// Reads one folder's entries without descending into its subfolders.
    func list(path: String) -> Opened {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0, let dir = fdopendir(fd) else {
            let code = errno
            if fd >= 0 { close(fd) }
            return code == EPERM || code == EACCES ? .blocked : .gone
        }
        defer { closedir(dir) }

        let display = displayPath(path)
        var entries = Entries()
        var fileCount = 0

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
                    entries.subfolders.append(Subfolder(name: entryName, blocks: blocks, modified: Self.date(st)))
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
            fileCount += 1
            entries.fileBlocks += blocks
            if blocks >= options.keepThreshold {
                let childPath = display == "/" ? "/" + entryName : display + "/" + entryName
                let modifiedDate = Self.date(st)
                entries.keptFiles.append(FileNode(name: entryName, path: childPath, isDirectory: false, size: blocks, modified: modifiedDate))
                if blocks >= options.largeFileThreshold {
                    let file = LargeFile(path: childPath, name: entryName, size: blocks, modified: modifiedDate)
                    lock.withLock { large.append(file) }
                }
            } else {
                entries.smallSize += blocks
                entries.smallCount += 1
            }
        }
        progress.add(files: fileCount, bytes: entries.fileBlocks)
        return .listed(entries)
    }

    func walk(path: String, name: String, ownBlocks: Int64, modified: Date?, depth: Int) -> FileNode {
        let display = displayPath(path)
        let node = FileNode(name: name, path: display, isDirectory: true, size: ownBlocks, modified: modified)
        if progress.isCancelled { return node }

        let entries: Entries
        switch list(path: path) {
        case .listed(let found):
            entries = found
        case .blocked:
            node.isBlocked = true
            lock.withLock { if blocked.count < 5000 { blocked.append(display) } }
            return node
        case .gone:
            return node
        }

        let subfolders = entries.subfolders
        let separator = path.hasSuffix("/") ? "" : "/"
        var results = [FileNode?](repeating: nil, count: subfolders.count)
        func scanSub(_ index: Int) -> FileNode {
            let sub = subfolders[index]
            return walk(path: path + separator + sub.name, name: sub.name, ownBlocks: sub.blocks, modified: sub.modified, depth: depth + 1)
        }
        if depth < options.parallelDepth, subfolders.count > 1 {
            let resultsLock = NSLock()
            DispatchQueue.concurrentPerform(iterations: subfolders.count) { index in
                let result = scanSub(index)
                resultsLock.withLock { results[index] = result }
            }
        } else {
            for index in subfolders.indices { results[index] = scanSub(index) }
        }

        var kept = entries.keptFiles
        var total = ownBlocks + entries.fileBlocks
        var smallSize = entries.smallSize
        var smallCount = entries.smallCount
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

    static func date(_ st: stat) -> Date? {
        Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
    }
}
