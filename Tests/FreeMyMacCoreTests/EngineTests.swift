import Foundation
import Testing
@testable import FreeMyMacCore

@Suite struct ScannerTests {
    @Test func addsUpSizesAndKeepsLargeItems() throws {
        let fixture = try Fixture()
        try fixture.file("big/a.bin", bytes: 3 << 20)
        try fixture.file("big/b.bin", bytes: 2 << 20)
        try fixture.file("tiny/c.bin", bytes: 4096)
        let result = DiskScanner.scan(root: fixture.root)

        let big = try #require(result.root.child(named: "big"))
        #expect(big.size >= 5 << 20)
        #expect(big.children.map(\.name) == ["a.bin", "b.bin"])
        #expect(result.root.child(named: "tiny") == nil, "small folders roll up into the parent")
        #expect(result.root.smallCount == 1)
        #expect(result.root.size == result.root.children.reduce(0) { $0 + $1.size } + result.root.smallSize + rootOwnBlocks(fixture.root))
    }

    private func rootOwnBlocks(_ path: String) -> Int64 {
        var st = stat()
        lstat(path, &st)
        return Int64(st.st_blocks) * 512
    }

    @Test func countsHardLinksOnce() throws {
        let fixture = try Fixture()
        let original = try fixture.file("one/data.bin", bytes: 2 << 20)
        try fixture.directory("two")
        try FileManager.default.linkItem(atPath: original, toPath: fixture.path("two/data.bin"))
        #expect(DiskScanner.measure(fixture.root) < 3 << 20)
    }

    @Test func doesNotFollowSymlinks() throws {
        let fixture = try Fixture()
        try fixture.file("real/data.bin", bytes: 4 << 20)
        try fixture.directory("elsewhere")
        try FileManager.default.createSymbolicLink(atPath: fixture.path("elsewhere/link"), withDestinationPath: fixture.path("real"))
        #expect(DiskScanner.measure(fixture.path("elsewhere")) < 1 << 20)
    }

    @Test func reportsUnreadableFolders() throws {
        let fixture = try Fixture()
        let locked = try fixture.directory("locked")
        try fixture.file("locked/secret.bin")
        chmod(locked, 0)
        defer { chmod(locked, 0o755) }
        let result = DiskScanner.scan(root: fixture.root)
        #expect(result.blocked == [locked])
        #expect(result.root.child(named: "locked")?.isBlocked == true)
    }

    @Test func listsLargeFilesAndDetachShrinksAncestors() throws {
        let fixture = try Fixture()
        try fixture.file("Movies/clip.mov", bytes: 101 << 20)
        try fixture.file("Movies/other.mov", bytes: 2 << 20)
        let result = DiskScanner.scan(root: fixture.root)
        #expect(result.largeFiles.map(\.name) == ["clip.mov"])

        let before = result.root.size
        let node = try #require(result.root.node(at: fixture.path("Movies/clip.mov")))
        let size = node.size
        node.detach()
        #expect(result.root.size == before - size)
        #expect(result.root.node(at: fixture.path("Movies/clip.mov")) == nil)
    }

    @Test func heaviestDigsPastSingleChildFolders() throws {
        let fixture = try Fixture()
        try fixture.file("Documents/wrapper/inner/a.bin", bytes: 8 << 20)
        try fixture.file("Documents/wrapper/inner/b.bin", bytes: 8 << 20)
        let result = DiskScanner.scan(root: fixture.root)
        let names = result.root.heaviest(limit: 3, minimum: 1 << 20).map(\.name)
        #expect(names.contains("a.bin") || names.contains("inner"))
        #expect(!names.contains("Documents"))
    }
}

@Suite struct CleanerTests {
    @Test func removesAllowedItemsAndReportsSize() throws {
        let fixture = try Fixture()
        let target = try fixture.file("Library/Caches/com.example/data.bin", bytes: 1 << 20)
        let size = try fixture.cleaner.removePermanently(fixture.path("Library/Caches/com.example"))
        #expect(size >= 1 << 20)
        #expect(!FileManager.default.fileExists(atPath: target))
    }

    @Test func refusesProtectedPathsBeforeTouchingThem() throws {
        let fixture = try Fixture()
        let keychain = try fixture.file("Library/Keychains/login.keychain-db")
        let document = try fixture.file("Documents/thesis.docx")
        #expect(throws: CleanError.self) { try fixture.cleaner.removePermanently(keychain) }
        #expect(throws: CleanError.self) { try fixture.cleaner.moveToTrash(keychain) }
        #expect(throws: CleanError.self) { try fixture.cleaner.removePermanently(fixture.path("Documents")) }
        #expect(throws: CleanError.self) { try fixture.cleaner.removePermanently(fixture.root) }
        #expect(FileManager.default.fileExists(atPath: keychain))
        #expect(FileManager.default.fileExists(atPath: document))
    }

    @Test func removesReadOnlyTreesLikeTheGoModuleCache() throws {
        let fixture = try Fixture()
        let inner = try fixture.directory("go/pkg/mod/example.com/lib@v1")
        try fixture.file("go/pkg/mod/example.com/lib@v1/file.go")
        chmod(fixture.path("go/pkg/mod/example.com/lib@v1/file.go"), 0o444)
        chmod(inner, 0o555)
        chmod(fixture.path("go/pkg/mod/example.com"), 0o555)
        try fixture.cleaner.removePermanently(fixture.path("go/pkg/mod"))
        #expect(!fixture.exists("go/pkg/mod"))
    }

    @Test func removingASymlinkLeavesItsTargetAlone() throws {
        let fixture = try Fixture()
        let precious = try fixture.file("Documents/precious.txt")
        try fixture.directory("Library/Caches")
        try FileManager.default.createSymbolicLink(atPath: fixture.path("Library/Caches/link"), withDestinationPath: fixture.path("Documents"))
        try fixture.cleaner.removePermanently(fixture.path("Library/Caches/link"))
        #expect(!fixture.exists("Library/Caches/link"))
        #expect(FileManager.default.fileExists(atPath: precious))
    }

    @Test func trashAndUndoRoundTrip() throws {
        let fixture = try Fixture()
        let file = try fixture.file("Downloads/movie.mov")
        let record = try fixture.cleaner.moveToTrash(file)
        #expect(!FileManager.default.fileExists(atPath: file))
        #expect(record.trashed.hasPrefix(fixture.env.trashPath))
        try fixture.cleaner.restore(record)
        #expect(FileManager.default.fileExists(atPath: file))
    }

    @Test func emptyTrashRemovesOnlyTheTrash() throws {
        let fixture = try Fixture()
        try fixture.file(".Trash/old.bin", bytes: 1 << 20)
        let keep = try fixture.file("Documents/keep.txt")
        let report = fixture.cleaner.emptyTrash()
        #expect(report.removed == 1)
        #expect(report.bytes >= 1 << 20)
        #expect(!fixture.exists(".Trash/old.bin"))
        #expect(fixture.exists(".Trash"), "the Trash folder itself has to survive")
        #expect(FileManager.default.fileExists(atPath: keep))
    }

    @Test func oneFailureDoesNotStopTheRest() throws {
        let fixture = try Fixture()
        try fixture.file("Library/Caches/ok/a.bin")
        let keychain = try fixture.file("Library/Keychains/login.keychain-db")
        let item = CleanupItem(id: "t", title: "t", detail: "", symbol: "", tier: .safe, action: .removePermanently, entries: [
            CatalogEntry(path: keychain, name: "k", size: 1, owner: nil),
            CatalogEntry(path: fixture.path("Library/Caches/ok"), name: "ok", size: 1, owner: nil),
        ])
        let report = fixture.cleaner.clean(item, running: [])
        #expect(report.removed == 1)
        #expect(report.failures.map(\.path) == [keychain])
        #expect(FileManager.default.fileExists(atPath: keychain))
        #expect(!fixture.exists("Library/Caches/ok"))
    }

    @Test func skipsAppsOpenedAfterTheListWasBuilt() throws {
        let fixture = try Fixture()
        try fixture.file("Library/Caches/com.example.editor/a.bin")
        let item = try #require(fixture.catalog().item("app-caches"))
        let report = fixture.cleaner.clean(item, running: [RunningApp(name: "Editor", bundleID: "com.example.editor")])
        #expect(report.skippedInUse == ["Editor"])
        #expect(report.removed == 0)
        #expect(fixture.exists("Library/Caches/com.example.editor/a.bin"))
    }

    @Test func reviewRowsDeleteOutrightWhenPermanentIsOn() throws {
        let fixture = try Fixture()
        try fixture.file("Downloads/setup.dmg")
        try fixture.file("Downloads/keep.pdf")
        let item = try #require(fixture.catalog().item("installers"))
        let report = fixture.cleaner.clean(item, running: [], permanently: true)
        #expect(report.removed == 1)
        #expect(report.trashed.isEmpty, "nothing to undo, because nothing went to the Trash")
        #expect(report.bytes > 0)
        #expect(!fixture.exists("Downloads/setup.dmg"))
        #expect(!fixture.exists(".Trash"))
        #expect(fixture.exists("Downloads/keep.pdf"))
    }

    @Test func permanentModeStillRefusesProtectedPaths() throws {
        let fixture = try Fixture()
        let keychain = try fixture.file("Library/Keychains/login.keychain-db")
        let document = try fixture.file("Documents/thesis.docx")
        let report = fixture.cleaner.deleteFully([keychain, fixture.path("Documents"), fixture.root])
        #expect(report.removed == 0)
        #expect(report.failures.count == 3)
        #expect(FileManager.default.fileExists(atPath: keychain))
        #expect(FileManager.default.fileExists(atPath: document))
    }

    @Test func permissionRefusalsEscalateOnceAndProtectedPathsNever() throws {
        let fixture = try Fixture()
        let locked = try fixture.directory("Downloads/locked")
        let owned = try fixture.file("Downloads/locked/rootowned.bin")
        let other = try fixture.file("Downloads/locked/also.bin")
        let free = try fixture.file("Downloads/mine.bin")
        let keychain = try fixture.file("Library/Keychains/login.keychain-db")
        // A read-only parent refuses the delete, the way a root-owned folder does.
        chmod(locked, 0o555)
        defer { chmod(locked, 0o755) }

        let calls = Recorder()
        fixture.cleaner.runAdmin = { paths in
            calls.append(paths)
            chmod(locked, 0o755)
            for path in paths { try? FileManager.default.removeItem(atPath: path) }
            return .finished
        }
        let report = fixture.cleaner.deleteFully([owned, free, keychain, other])

        #expect(calls.batches == [[owned, other]], "one prompt for both, with the protected file never included")
        #expect(report.removed == 3)
        #expect(report.failures.map(\.path) == [keychain])
        #expect(FileManager.default.fileExists(atPath: keychain))
    }

    @Test func cancellingThePasswordPromptIsNotAFailure() throws {
        let fixture = try Fixture()
        let locked = try fixture.directory("Downloads/locked")
        let owned = try fixture.file("Downloads/locked/rootowned.bin")
        chmod(locked, 0o555)
        defer { chmod(locked, 0o755) }
        fixture.cleaner.runAdmin = { _ in .cancelled }
        let report = fixture.cleaner.deleteFully([owned])
        #expect(report.wasCancelled)
        #expect(report.failures.isEmpty)
        #expect(report.removed == 0)
        #expect(FileManager.default.fileExists(atPath: owned))
    }

    @Test func whatAdminCouldNotDeleteIsReportedHonestly() throws {
        let fixture = try Fixture()
        let locked = try fixture.directory("Downloads/locked")
        let owned = try fixture.file("Downloads/locked/sip-protected.bin")
        chmod(locked, 0o555)
        defer { chmod(locked, 0o755) }
        fixture.cleaner.runAdmin = { _ in .finished }
        let report = fixture.cleaner.deleteFully([owned])
        #expect(report.removed == 0)
        #expect(report.bytes == 0)
        #expect(report.failures.map(\.path) == [owned])
    }

    @Test func adminScriptQuotesHostilePaths() {
        let script = Cleaner.adminScript(paths: ["/Library/Caches/it's \"odd\"; rm -rf ~"])
        #expect(script == #"do shell script "/bin/rm -rf -- '/Library/Caches/it'\\''s \"odd\"; rm -rf ~'" with administrator privileges"#)
    }
}

@Suite struct CatalogTests {
    private let old = Date().addingTimeInterval(-200 * 86_400)

    @Test func safeRowsNeverIncludeYourFilesOrAppleCaches() throws {
        let fixture = try Fixture()
        try fixture.file("Documents/thesis.docx")
        try fixture.file("Desktop/photo.jpg")
        try fixture.file("Library/Caches/com.apple.Safari/a.bin")
        try fixture.file("Library/Caches/GeoServices/a.bin")
        try fixture.file("Library/Caches/com.vendor.tool/a.bin")
        try fixture.file("Library/Application Support/Notes App/notes.db")
        let items = fixture.catalog()
        let safePaths = items.filter { $0.tier == .safe }.allPaths
        #expect(safePaths == [fixture.path("Library/Caches/com.vendor.tool")])
    }

    @Test func safeRowsAreRemovedAndReviewRowsGoToTrash() throws {
        let fixture = try Fixture()
        try fixture.file("Library/Caches/com.vendor.tool/a.bin")
        try fixture.file("Downloads/setup.dmg")
        let items = fixture.catalog()
        #expect(items.item("app-caches")?.action == .removePermanently)
        #expect(items.item("installers")?.action == .moveToTrash)
        #expect(items.item("installers")?.tier == .review)
    }

    @Test func noPathIsCountedTwice() throws {
        let fixture = try Fixture()
        try fixture.file("Library/Caches/pip/a.bin")
        try fixture.file("Library/Caches/Yarn/a.bin")
        try fixture.file("Library/Caches/Firefox/a.bin")
        try fixture.file("Library/Caches/com.vendor.tool/a.bin")
        try fixture.file(".npm/_cacache/a.bin")
        let paths = fixture.catalog().allPaths
        #expect(Set(paths).count == paths.count)
        #expect(paths.contains(fixture.path("Library/Caches/pip")))
    }

    @Test func doesNotTrustACacheThatIsReallyASymlink() throws {
        let fixture = try Fixture()
        try fixture.file("Documents/important/a.bin")
        try fixture.directory(".npm")
        try FileManager.default.createSymbolicLink(atPath: fixture.path(".npm/_cacache"), withDestinationPath: fixture.path("Documents/important"))
        #expect(!fixture.catalog().allPaths.contains(fixture.path(".npm/_cacache")))
    }

    @Test func webCachesNeedARealChromiumFolder() throws {
        let fixture = try Fixture()
        try fixture.file("Library/Application Support/Chatty/Local State")
        try fixture.file("Library/Application Support/Chatty/Cache/a.bin")
        try fixture.file("Library/Application Support/Chatty/IndexedDB/messages.db")
        try fixture.file("Library/Application Support/Ledger/Cache/invoices.db")
        let entries = try #require(fixture.catalog().item("electron-caches")).entries.map(\.path)
        #expect(entries == [fixture.path("Library/Application Support/Chatty/Cache")])
    }

    @Test func onlyIdleProjectsCountAsStale() throws {
        let fixture = try Fixture()
        try fixture.file("Documents/idle/package.json", modified: old)
        try fixture.file("Documents/idle/node_modules/lib/index.js")
        try fixture.file("Documents/active/package.json")
        try fixture.file("Documents/active/node_modules/lib/index.js")
        try fixture.file("Documents/py/main.py", modified: old)
        try fixture.file("Documents/py/venv/pyvenv.cfg")
        try fixture.file("Documents/notavenv/note.txt", modified: old)
        try fixture.file("Documents/notavenv/venv/my-trip-photos.txt")
        try fixture.file("Documents/notrust/notes.txt", modified: old)
        try fixture.file("Documents/notrust/target/quarterly-goals.txt")
        let entries = try #require(fixture.catalog().item("project-deps")).entries.map(\.path)
        #expect(Set(entries) == [fixture.path("Documents/idle/node_modules"), fixture.path("Documents/py/venv")])
    }

    @Test func runningAppMatching() {
        let entry = { (owner: String) in CatalogEntry(path: "/x", name: "x", size: 1, owner: owner) }
        let chrome = RunningApp(name: "Google Chrome", bundleID: "com.google.Chrome")
        let antigravity = RunningApp(name: "Antigravity", bundleID: "com.google.antigravity")
        #expect(CatalogBuilder.runningOwner(of: entry("Google Chrome"), running: [chrome]) == "Google Chrome")
        #expect(CatalogBuilder.runningOwner(of: entry("com.google.Chrome"), running: [chrome]) == "Google Chrome")
        #expect(CatalogBuilder.runningOwner(of: entry("com.google.Chrome.helper"), running: [chrome]) == "Google Chrome")
        #expect(CatalogBuilder.runningOwner(of: entry("com.google.antigravity"), running: [antigravity]) == "Antigravity")
        #expect(CatalogBuilder.runningOwner(of: entry("Firefox"), running: [chrome]) == nil)
    }

    @Test func parsesHomebrewEstimates() {
        #expect(CatalogBuilder.parseBrewEstimate("==> This operation would free approximately 1.5GB of disk space.") == Int64(1.5 * 1_073_741_824))
        #expect(CatalogBuilder.parseBrewEstimate("Would remove: x (2 files, 50KB)\nThis operation would free approximately 512MB of disk space.") == 512 << 20)
        #expect(CatalogBuilder.parseBrewEstimate("nothing to do") == 0)
    }

    @Test func leftoversMatchExactlyAndMarkUserData() throws {
        let fixture = try Fixture()
        try fixture.file("Library/Caches/com.example.notes/a.bin")
        try fixture.file("Library/Preferences/com.example.notes.plist")
        try fixture.file("Library/Application Support/Notes/notes.db")
        try fixture.file("Library/Application Support/Notes Pro/keep.db")
        let app = InstalledApp(path: fixture.path("Applications/Notes.app"), name: "Notes", bundleID: "com.example.notes", size: 1, lastUsed: nil)
        let leftovers = AppInventory.leftovers(for: app, env: fixture.env, safety: fixture.safety)
        #expect(Set(leftovers.map(\.path)) == [
            fixture.path("Library/Caches/com.example.notes"),
            fixture.path("Library/Preferences/com.example.notes.plist"),
            fixture.path("Library/Application Support/Notes"),
        ])
        #expect(leftovers.filter(\.isUserData).count == 2)
    }
}

@Suite struct BreakdownTests {
    @Test func segmentsAlwaysAddUpToTheWholeDisk() throws {
        let fixture = try Fixture()
        try fixture.file("Documents/a.bin", bytes: 4 << 20)
        try fixture.file("Library/b.bin", bytes: 3 << 20)
        try fixture.file(".cache/c.bin", bytes: 2 << 20)
        try fixture.file("Applications/Foo.app/d.bin", bytes: 2 << 20)
        let root = DiskScanner.scan(root: fixture.root).root
        let volume = VolumeInfo(total: 1 << 30, free: 200 << 20, dataUsed: 700 << 20)
        let segments = StorageBreakdown.segments(volume: volume, root: root, env: fixture.env)
        #expect(segments.reduce(0) { $0 + $1.size } == volume.total)

        func size(_ kind: StorageSegment.Kind) -> Int64 { segments.first { $0.kind == kind }?.size ?? 0 }
        #expect(size(.files) >= 4 << 20)
        #expect(size(.appData) >= 3 << 20)
        #expect(size(.developer) >= 2 << 20)
        #expect(size(.apps) >= 2 << 20)
        #expect(size(.macOS) == volume.used - volume.dataUsed)
        #expect(size(.hidden) > 600 << 20, "what the scan can't see is shown, not lost")
    }

    @Test func scanningMoreThanAPFSReportsStillAddsUp() throws {
        let fixture = try Fixture()
        try fixture.file("Documents/a.bin", bytes: 8 << 20)
        let root = DiskScanner.scan(root: fixture.root).root
        let volume = VolumeInfo(total: 1 << 30, free: 500 << 20, dataUsed: 1 << 20)
        let segments = StorageBreakdown.segments(volume: volume, root: root, env: fixture.env)
        #expect(segments.first { $0.kind == .hidden } == nil)
        #expect(segments.reduce(0) { $0 + $1.size } >= volume.total)
    }

    @Test func beforeTheFirstScanEverythingIsHidden() {
        let env = FreeMyMacEnv(home: NSTemporaryDirectory(), isFixture: true)
        let volume = VolumeInfo(total: 1000, free: 100, dataUsed: 700)
        let segments = StorageBreakdown.segments(volume: volume, root: nil, env: env)
        #expect(segments.map(\.size) == [700, 200, 100])
    }

    @Test func realVolumeFiguresMakeSense() throws {
        let volume = try #require(VolumeInfo.current())
        #expect(volume.total > 0)
        #expect(volume.free > 0)
        #expect(volume.dataUsed <= volume.used)

        // Has to agree with df, within what can change between the two readings.
        let output = try #require(CommandRunner.run("/bin/df", ["-k", FreeMyMacEnv.dataVolume]))
        let columns = try #require(output.split(separator: "\n").last).split(whereSeparator: \.isWhitespace)
        let dfUsed = try #require(Int64(columns[2])) * 1024
        let dfFree = try #require(Int64(columns[3])) * 1024
        #expect(abs(volume.dataUsed - dfUsed) < 1 << 30)
        #expect(abs(volume.free - dfFree) < 1 << 30)
        #expect(volume.used - volume.dataUsed > 1 << 30, "macOS's own volumes have to show up as more than nothing")
    }
}
