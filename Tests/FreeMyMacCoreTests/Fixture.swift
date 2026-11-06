import Foundation
@testable import FreeMyMacCore

/// A throwaway home folder. Every test that removes files works inside one.
final class Fixture {
    let root: String
    let env: FreeMyMacEnv
    let safety: SafetyGuard
    let cleaner: Cleaner
    private let fm = FileManager.default

    init() throws {
        let path = NSTemporaryDirectory() + "freemymac-test-" + UUID().uuidString
        try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        env = FreeMyMacEnv(home: path, isFixture: true)
        root = env.home
        safety = SafetyGuard(env: env)
        cleaner = Cleaner(env: env, safety: safety)
    }

    deinit {
        // Read-only folders from tests would otherwise make cleanup fail.
        if let walker = fm.enumerator(atPath: root) {
            for case let relative as String in walker {
                let path = root + "/" + relative
                var st = stat()
                if lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR { chmod(path, 0o755) }
            }
        }
        chmod(root, 0o755)
        try? fm.removeItem(atPath: root)
    }

    func path(_ relative: String) -> String { root + "/" + relative }

    @discardableResult
    func file(_ relative: String, bytes: Int = 8192, modified: Date? = nil) throws -> String {
        let target = path(relative)
        try fm.createDirectory(atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(repeating: 0x61, count: bytes).write(to: URL(fileURLWithPath: target))
        if let modified { try fm.setAttributes([.modificationDate: modified], ofItemAtPath: target) }
        return target
    }

    @discardableResult
    func directory(_ relative: String) throws -> String {
        let target = path(relative)
        try fm.createDirectory(atPath: target, withIntermediateDirectories: true)
        return target
    }

    func exists(_ relative: String) -> Bool {
        var st = stat()
        return lstat(path(relative), &st) == 0
    }

    func catalog(now: Date = Date()) -> [CleanupItem] {
        var input = CatalogBuilder.Input(env: env, safety: safety)
        input.now = now
        return CatalogBuilder.build(input)
    }
}

final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [[String]] = []

    func append(_ paths: [String]) { lock.withLock { stored.append(paths) } }
    var batches: [[String]] { lock.withLock { stored } }
}

extension Array where Element == CleanupItem {
    func item(_ id: String) -> CleanupItem? { first { $0.id == id } }
    var allPaths: [String] { flatMap { $0.entries.map(\.path) } }
}
