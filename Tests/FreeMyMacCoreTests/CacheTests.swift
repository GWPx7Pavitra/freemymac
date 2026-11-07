import Foundation
import Testing
@testable import FreeMyMacCore

/// The tree as plain values, so two trees can be compared exactly.
private func flatten(_ node: FileNode) -> [String] {
    var lines: [String] = []
    func visit(_ node: FileNode) {
        lines.append("\(node.path)|\(node.isDirectory)|\(node.size)|\(node.smallSize)|\(node.smallCount)|\(node.isBlocked)")
        node.children.forEach(visit)
    }
    visit(node)
    return lines.sorted()
}

private func refresh(_ tree: FileNode, root: String, changes: [DiskChange], attempts: Int = 5) {
    guard attempts > 0 else {
        Issue.record("the refresh kept asking to retry")
        return
    }
    guard case .refresh(let targets) = TreeRefresher.plan(changes, root: tree, rootDiskPath: root) else {
        Issue.record("expected a partial refresh, got a full scan")
        return
    }
    var retries: [DiskChange] = []
    for listing in TreeRefresher.list(targets) {
        if case .retry(let change) = TreeRefresher.apply(listing, to: tree) { retries.append(change) }
    }
    if !retries.isEmpty { refresh(tree, root: root, changes: retries, attempts: attempts - 1) }
}

@Suite struct ScanCacheTests {
    @Test func roundTripsTheWholeTree() throws {
        let fixture = try Fixture()
        try fixture.file("Movies/clip.mov", bytes: 3 << 20)
        try fixture.file("Movies/notes.txt", bytes: 4096)
        try fixture.file("Projects/app/node_modules/pkg/index.js", bytes: 2 << 20)
        try fixture.file("Projects/app/README.md", bytes: 100)
        let locked = try fixture.directory("Locked")
        chmod(locked, 0)
        defer { chmod(locked, 0o755) }

        let scanned = DiskScanner.scan(root: fixture.root).root
        let header = ScanCache.Header(scanRoot: fixture.root, volumeID: "volume", eventID: 42,
                                      scannedAt: Date(timeIntervalSince1970: 1_800_000_000), hadFullDiskAccess: true)
        let data = ScanCache.encode(scanned, header: header)
        let (loaded, loadedHeader) = try #require(ScanCache.decode(data))

        #expect(loadedHeader == header)
        #expect(flatten(loaded) == flatten(scanned))
        let clip = try #require(loaded.node(at: fixture.path("Movies/clip.mov")))
        #expect(clip.parent?.parent === loaded, "parents are linked back up")
        #expect(clip.modified != nil)
    }

    @Test func rejectsDamagedFiles() throws {
        let fixture = try Fixture()
        try fixture.file("a/b.bin", bytes: 2 << 20)
        let tree = DiskScanner.scan(root: fixture.root).root
        let header = ScanCache.Header(scanRoot: fixture.root, volumeID: "v", eventID: 1, scannedAt: Date(), hadFullDiskAccess: true)
        let data = ScanCache.encode(tree, header: header)

        #expect(ScanCache.decode(data.dropLast(3)) == nil)
        #expect(ScanCache.decode(Data("not a cache".utf8)) == nil)
        var trailing = data
        trailing.append(0)
        #expect(ScanCache.decode(trailing) == nil)
    }
}

@Suite struct TreeRefresherTests {
    @Test func matchesAFreshScanAfterChanges() throws {
        let fixture = try Fixture()
        try fixture.file("Library/Caches/app/blob.bin", bytes: 6 << 20)
        try fixture.file("Library/Caches/other/blob.bin", bytes: 2 << 20)
        try fixture.file("Documents/report.pdf", bytes: 3 << 20)
        try fixture.file("Documents/small.txt", bytes: 4096)
        let tree = DiskScanner.scan(root: fixture.root).root

        // A cache cleared, a file grown, a new folder, and a small folder that grew big.
        try FileManager.default.removeItem(atPath: fixture.path("Library/Caches/app"))
        try fixture.file("Documents/report.pdf", bytes: 5 << 20)
        try fixture.file("Downloads/new/movie.mp4", bytes: 4 << 20)
        try fixture.file("Documents/tiny/grew.bin", bytes: 4096)
        try fixture.file("Documents/tiny/grew.bin", bytes: 3 << 20)

        refresh(tree, root: fixture.root, changes: [
            DiskChange(path: fixture.path("Library/Caches") + "/"),
            DiskChange(path: fixture.path("Library/Caches/app")),
            DiskChange(path: fixture.path("Documents")),
            DiskChange(path: fixture.path("Documents/tiny")),
            DiskChange(path: fixture.root),
            DiskChange(path: fixture.path("Downloads/new")),
        ])

        let fresh = DiskScanner.scan(root: fixture.root).root
        #expect(flatten(tree) == flatten(fresh))
        #expect(tree.node(at: fixture.path("Library/Caches/app")) == nil)
        #expect(tree.node(at: fixture.path("Downloads/new/movie.mp4"))?.parent?.parent?.parent === tree)
    }

    @Test func keepsKnownSubfoldersWithoutReadingThem() throws {
        let fixture = try Fixture()
        try fixture.file("Projects/huge/data.bin", bytes: 4 << 20)
        try fixture.file("Projects/notes.txt", bytes: 4096)
        let tree = DiskScanner.scan(root: fixture.root).root
        let huge = try #require(tree.node(at: fixture.path("Projects/huge")))

        try fixture.file("Projects/notes.txt", bytes: 2 << 20)
        refresh(tree, root: fixture.root, changes: [DiskChange(path: fixture.path("Projects"))])

        #expect(tree.node(at: fixture.path("Projects/huge")) === huge, "the unchanged subfolder is the same node")
        #expect(tree.node(at: fixture.path("Projects/notes.txt")) != nil)
        #expect(flatten(tree) == flatten(DiskScanner.scan(root: fixture.root).root))
    }

    @Test func rereadsEverythingWhenMacOSLostTrack() throws {
        let fixture = try Fixture()
        try fixture.file("a/b/c.bin", bytes: 2 << 20)
        let tree = DiskScanner.scan(root: fixture.root).root
        try fixture.file("a/b/d.bin", bytes: 3 << 20)

        // Only "a" is reported, but with "everything": a/b must be read again too.
        refresh(tree, root: fixture.root, changes: [DiskChange(path: fixture.path("a"), everything: true)])
        #expect(flatten(tree) == flatten(DiskScanner.scan(root: fixture.root).root))
    }

    @Test func changesToTheTopNeedAFullScan() throws {
        let fixture = try Fixture()
        try fixture.file("a/b.bin", bytes: 2 << 20)
        let tree = DiskScanner.scan(root: fixture.root).root
        #expect(TreeRefresher.plan([DiskChange(path: fixture.root, everything: true)], root: tree, rootDiskPath: fixture.root) == .fullScan)
        #expect(TreeRefresher.plan([DiskChange(path: "/somewhere/else")], root: tree, rootDiskPath: fixture.root) == .refresh([]))
    }

    @Test func summaryFindsLargeFilesInTheTree() throws {
        let fixture = try Fixture()
        try fixture.file("Movies/clip.mov", bytes: 101 << 20)
        try fixture.file("Movies/other.mov", bytes: 2 << 20)
        let result = DiskScanner.scan(root: fixture.root)
        #expect(DiskScanner.summarize(result.root).largeFiles.map(\.path) == result.largeFiles.map(\.path))
    }

    @Test func catalogUsesTheTreeForSizes() throws {
        let fixture = try Fixture()
        try fixture.file("Library/Caches/com.example.app/blob.bin", bytes: 3 << 20)
        let tree = SharedTree(root: DiskScanner.scan(root: fixture.root).root)
        var input = CatalogBuilder.Input(env: fixture.env, safety: fixture.safety)
        input.tree = tree

        // Grow the folder on disk without telling the tree: the catalog reports what the tree knows.
        try fixture.file("Library/Caches/com.example.app/more.bin", bytes: 4 << 20)
        let entry = try #require(CatalogBuilder.build(input).item("app-caches")?.entries.first)
        #expect(entry.size == tree.size(of: fixture.path("Library/Caches/com.example.app")))
        #expect(entry.size < 5 << 20)
    }

    @Test func staleDependenciesAreFoundThroughTheTree() throws {
        let fixture = try Fixture()
        let old = Date().addingTimeInterval(-90 * 86_400)
        try fixture.file("Code/idle/node_modules/pkg/index.js", bytes: 2 << 20)
        try fixture.file("Code/idle/package.json", bytes: 100, modified: old)
        try fixture.file("Code/busy/node_modules/pkg/index.js", bytes: 2 << 20)
        try fixture.file("Code/busy/package.json", bytes: 100)
        var input = CatalogBuilder.Input(env: fixture.env, safety: fixture.safety)
        input.tree = SharedTree(root: DiskScanner.scan(root: fixture.root).root)

        let paths = CatalogBuilder.build(input).item("project-deps")?.entries.map(\.path) ?? []
        #expect(paths == [fixture.path("Code/idle/node_modules")])
    }
}
