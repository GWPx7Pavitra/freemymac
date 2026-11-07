import Foundation

/// A folder macOS says has changed. `everything` means macOS lost track of the
/// details, so the folder and everything under it must be read again.
public struct DiskChange: Sendable, Hashable {
    public let path: String
    public let everything: Bool

    public init(path: String, everything: Bool = false) {
        self.path = path
        self.everything = everything
    }
}

/// Keeps a scanned tree current without scanning the whole disk again.
///
/// macOS reports each folder whose own entries changed. That folder is listed
/// again on its own, and its subfolders keep the sizes the tree already has,
/// because any change inside them is reported separately. Only folders new to
/// the tree are walked in full.
///
/// Work is split three ways so the window never waits on the disk: `plan` reads
/// the tree on the main thread, `list` reads the disk in the background, and
/// `apply` changes the tree on the main thread inside `SharedTree.write`.
public enum TreeRefresher {
    public struct Target: Sendable, Hashable {
        /// The folder's path as the tree shows it.
        public let path: String
        /// Where the folder is read from on disk.
        public let diskPath: String
        /// Subfolders the tree already holds, which keep their sizes.
        public let knownFolders: Set<String>
        public let everything: Bool
    }

    public enum Plan: Sendable, Equatable {
        /// The changes touch the top of the tree, so only a full scan is right.
        case fullScan
        case refresh([Target])
    }

    /// A folder as read from disk. Its new subtrees are built in the background
    /// and handed to the main thread, which is their only user from then on.
    public struct Listing: @unchecked Sendable {
        enum Child {
            case known(String)
            case fresh(FileNode)
        }

        enum State {
            case listed(ownBlocks: Int64, entries: Walker.Entries, children: [Child])
            case blocked
            case gone
        }

        let path: String
        let everything: Bool
        let state: State
    }

    public enum Outcome: Equatable {
        case applied
        /// The tree changed since the plan. Refresh this change again.
        case retry(DiskChange)
        case skipped
    }

    // MARK: - Plan (main thread)

    public static func plan(_ changes: [DiskChange], root: FileNode, rootDiskPath: String) -> Plan {
        var wanted: [String: Bool] = [:]
        for change in changes {
            var path = normalize(change.path)
            guard contains(root.path, path) else { continue }
            var everything = change.everything
            while true {
                if let node = root.node(at: path), node.isDirectory,
                   isDirectory(diskPath(path, root: root, rootDiskPath: rootDiskPath)) {
                    // node(at:) matches names without regard to case, as APFS does.
                    path = node.path
                    break
                }
                // Gone, or new to the tree: listing the parent settles it, and
                // walks anything new in full anyway.
                if path == root.path { return .fullScan }
                path = parent(of: path)
                everything = false
            }
            wanted[path] = (wanted[path] ?? false) || everything
        }
        if wanted[root.path] == true { return .fullScan }

        let everythingRoots = wanted.filter(\.value).map(\.key)
        var targets: [Target] = []
        for (path, everything) in wanted {
            // A folder read in full already covers every change inside it.
            if everythingRoots.contains(where: { $0 != path && contains($0, path) }) { continue }
            guard let node = root.node(at: path) else { continue }
            let known = everything ? [] : Set(node.children.filter(\.isDirectory).map(\.name))
            targets.append(Target(path: path, diskPath: diskPath(path, root: root, rootDiskPath: rootDiskPath),
                                  knownFolders: known, everything: everything))
        }
        // Deepest first, so a parent's listing sees its children's new sizes.
        targets.sort { depth($0.path) > depth($1.path) }
        return .refresh(targets)
    }

    // MARK: - List (background)

    public static func list(_ targets: [Target], options: DiskScanner.Options = .init()) -> [Listing] {
        targets.map { list($0, options: options) }
    }

    static func list(_ target: Target, options: DiskScanner.Options) -> Listing {
        var st = stat()
        guard lstat(target.diskPath, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else {
            return Listing(path: target.path, everything: target.everything, state: .gone)
        }
        let walker = Walker(options: options, progress: ScanProgress(), device: st.st_dev)
        switch walker.list(path: target.diskPath) {
        case .gone:
            return Listing(path: target.path, everything: target.everything, state: .gone)
        case .blocked:
            return Listing(path: target.path, everything: target.everything, state: .blocked)
        case .listed(let entries):
            let separator = target.diskPath.hasSuffix("/") ? "" : "/"
            let children: [Listing.Child] = entries.subfolders.map { sub in
                if target.knownFolders.contains(sub.name) { return .known(sub.name) }
                return .fresh(walker.walk(path: target.diskPath + separator + sub.name, name: sub.name,
                                          ownBlocks: sub.blocks, modified: sub.modified, depth: 1))
            }
            return Listing(path: target.path, everything: target.everything,
                           state: .listed(ownBlocks: Int64(st.st_blocks) * 512, entries: entries, children: children))
        }
    }

    // MARK: - Apply (main thread, inside SharedTree.write)

    public static func apply(_ listing: Listing, to root: FileNode, options: DiskScanner.Options = .init()) -> Outcome {
        guard let node = root.node(at: listing.path), node.isDirectory else {
            return .retry(DiskChange(path: parent(of: listing.path)))
        }

        var kept: [FileNode] = []
        var total: Int64
        var smallSize: Int64 = 0
        var smallCount = 0
        var isBlocked = false

        switch listing.state {
        case .gone:
            // Removed after the plan. Its parent's listing takes it out.
            if node === root { return .skipped }
            return .retry(DiskChange(path: parent(of: listing.path)))
        case .blocked:
            total = 0
            isBlocked = true
        case .listed(let ownBlocks, let entries, let children):
            kept = entries.keptFiles
            total = ownBlocks + entries.fileBlocks
            smallSize = entries.smallSize
            smallCount = entries.smallCount
            for child in children {
                let sub: FileNode
                switch child {
                case .known(let name):
                    // Folded into its parent's small items since the plan was made.
                    guard let existing = node.child(named: name), existing.isDirectory else {
                        return .retry(DiskChange(path: listing.path, everything: true))
                    }
                    sub = existing
                case .fresh(let fresh):
                    sub = fresh
                }
                total += sub.size
                if sub.size >= options.keepThreshold || sub.isBlocked {
                    kept.append(sub)
                } else {
                    smallSize += sub.size
                    smallCount += 1
                }
            }
        }

        let keptIDs = Set(kept.map(ObjectIdentifier.init))
        for old in node.children where !keptIDs.contains(ObjectIdentifier(old)) { old.parent = nil }
        kept.sort { $0.size > $1.size }
        for child in kept { child.parent = node }

        let delta = total - node.size
        node.children = kept
        node.smallSize = smallSize
        node.smallCount = smallCount
        node.isBlocked = isBlocked
        node.size = total
        var current = node
        while let ancestor = current.parent {
            ancestor.size += delta
            if delta != 0 { ancestor.children.sort { $0.size > $1.size } }
            current = ancestor
        }
        return .applied
    }

    // MARK: - Paths

    /// FSEvents reports `/Users/x/` style paths with a trailing slash, and paths
    /// with no firmlink in `/System/Volumes/Data/...` form.
    static func normalize(_ path: String) -> String {
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        return displayPath(trimmed)
    }

    static func contains(_ ancestor: String, _ path: String) -> Bool {
        if ancestor == path || ancestor == "/" { return true }
        return path.lowercased().hasPrefix(ancestor.lowercased() + "/")
    }

    static func parent(of path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    static func depth(_ path: String) -> Int {
        path.split(separator: "/").count
    }

    static func diskPath(_ path: String, root: FileNode, rootDiskPath: String) -> String {
        let relative = root.path == "/" ? path : String(path.dropFirst(root.path.count))
        if relative.isEmpty || relative == "/" { return rootDiskPath }
        return rootDiskPath == "/" ? relative : rootDiskPath + relative
    }

    static func isDirectory(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }
}
