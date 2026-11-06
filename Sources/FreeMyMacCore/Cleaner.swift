import Foundation

public struct TrashRecord: Identifiable, Sendable, Equatable {
    public let original: String
    public let trashed: String
    public var id: String { trashed }
}

public struct CleanFailure: Identifiable, Sendable, Equatable {
    public let path: String
    public let reason: String
    public var id: String { path }

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }
}

public struct CleanReport: Sendable {
    public var bytes: Int64 = 0
    public var bytesTrashed: Int64 = 0
    public var removed = 0
    public var skippedInUse: [String] = []
    public var failures: [CleanFailure] = []
    public var trashed: [TrashRecord] = []
    public var wasCancelled = false

    public init() {}

    public mutating func merge(_ other: CleanReport) {
        bytes += other.bytes
        bytesTrashed += other.bytesTrashed
        removed += other.removed
        skippedInUse += other.skippedInUse
        failures += other.failures
        trashed += other.trashed
        wasCancelled = wasCancelled || other.wasCancelled
    }
}

public enum CleanError: LocalizedError, Equatable {
    case blocked(String)

    public var errorDescription: String? {
        switch self {
        case .blocked(let reason): return reason
        }
    }
}

/// Everything that removes files lives here, behind `SafetyGuard`.
public final class Cleaner: @unchecked Sendable {
    public let env: FreeMyMacEnv
    public let safety: SafetyGuard
    private let fm = FileManager.default

    public init(env: FreeMyMacEnv, safety: SafetyGuard) {
        self.env = env
        self.safety = safety
    }

    // MARK: - Single items

    @discardableResult
    public func removePermanently(_ path: String) throws -> Int64 {
        if case .blocked(let reason) = safety.check(path) { throw CleanError.blocked(reason) }
        let size = DiskScanner.measure(path)
        do {
            try fm.removeItem(atPath: path)
        } catch {
            // Go's module cache and some package stores are read-only on purpose,
            // so a plain delete gets refused until the owner's write bit is back.
            makeWritable(path)
            try fm.removeItem(atPath: path)
        }
        log("removed", path, size)
        return size
    }

    public func moveToTrash(_ path: String) throws -> TrashRecord {
        if case .blocked(let reason) = safety.check(path) { throw CleanError.blocked(reason) }
        let size = DiskScanner.measure(path)
        let destination: String
        if env.isFixture {
            try fm.createDirectory(atPath: env.trashPath, withIntermediateDirectories: true)
            destination = env.trashPath + "/" + UUID().uuidString.prefix(8) + "-" + (path as NSString).lastPathComponent
            try fm.moveItem(atPath: path, toPath: destination)
        } else {
            var result: NSURL?
            try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &result)
            destination = result?.path ?? env.trashPath
        }
        log("trashed", path, size)
        return TrashRecord(original: path, trashed: destination)
    }

    public func restore(_ record: TrashRecord) throws {
        try fm.moveItem(atPath: record.trashed, toPath: record.original)
        log("restored", record.original, 0)
    }

    public func emptyTrash() -> CleanReport {
        var report = CleanReport()
        guard let names = try? fm.contentsOfDirectory(atPath: env.trashPath) else {
            report.failures.append(CleanFailure(path: env.trashPath, reason: "Full Disk Access is needed to empty the Trash."))
            return report
        }
        for name in names where name != ".DS_Store" {
            let path = env.trashPath + "/" + name
            do {
                report.bytes += try removePermanently(path)
                report.removed += 1
            } catch {
                report.failures.append(CleanFailure(path: path, reason: error.localizedDescription))
            }
        }
        return report
    }

    // MARK: - Catalog items

    /// `running` is read at the moment of cleaning, not when the list was built,
    /// so an app opened since the scan is still skipped.
    public func clean(_ item: CleanupItem, entries chosen: [CatalogEntry]? = nil, running: [RunningApp], permanently: Bool = false) -> CleanReport {
        var report = CleanReport()
        let entries = chosen ?? item.entries

        var usable: [CatalogEntry] = []
        for entry in entries {
            if let app = CatalogBuilder.runningOwner(of: entry, running: running) {
                if !report.skippedInUse.contains(app) { report.skippedInUse.append(app) }
            } else {
                usable.append(entry)
            }
        }

        switch item.action {
        case .emptyTrash:
            report.merge(emptyTrash())
        case .removePermanently:
            report.merge(deleteFully(usable.map(\.path)))
        case .moveToTrash where permanently:
            report.merge(deleteFully(usable.map(\.path)))
        case .moveToTrash:
            for entry in usable {
                do {
                    report.trashed.append(try moveToTrash(entry.path))
                    report.bytesTrashed += entry.size
                    report.removed += 1
                } catch {
                    report.failures.append(CleanFailure(path: entry.path, reason: error.localizedDescription))
                }
            }
        case .removeAsAdmin:
            report.merge(removeAsAdmin(usable.map(\.path)))
        case .command(let executable, let arguments):
            if CommandRunner.run(executable, arguments) == nil {
                report.failures.append(CleanFailure(path: executable, reason: "The command couldn't be started."))
            } else {
                report.bytes += item.estimatedSize
                report.removed += 1
                log("ran", ([executable] + arguments).joined(separator: " "), item.estimatedSize)
            }
        }
        return report
    }

    // MARK: - Deleting for good

    /// Deletes each path outright. Your own files need no password. Anything
    /// macOS refuses on permissions is retried together behind one password
    /// prompt, after the safety check, so a refusal never widens what can go.
    public func deleteFully(_ paths: [String]) -> CleanReport {
        var report = CleanReport()
        var refused: [String] = []
        for path in paths {
            do {
                report.bytes += try removePermanently(path)
                report.removed += 1
            } catch let error as CleanError {
                report.failures.append(CleanFailure(path: path, reason: error.localizedDescription))
            } catch {
                if Self.isPermissionError(error) {
                    refused.append(path)
                } else {
                    report.failures.append(CleanFailure(path: path, reason: error.localizedDescription))
                }
            }
        }
        if !refused.isEmpty { report.merge(removeAsAdmin(refused)) }
        return report
    }

    static func isPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileWriteNoPermissionError { return true }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(EACCES) || nsError.code == Int(EPERM) { return true }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError { return isPermissionError(underlying) }
        return false
    }

    // MARK: - Administrator removal

    public enum AdminResult: Sendable, Equatable {
        case finished
        case cancelled
        case failed(String)
    }

    /// Runs the actual privileged removal. Replaceable so tests can check what
    /// would be escalated without a password prompt.
    public var runAdmin: @Sendable ([String]) -> AdminResult = Cleaner.runAdminPrompt

    private func removeAsAdmin(_ paths: [String]) -> CleanReport {
        var report = CleanReport()
        var allowed: [(path: String, size: Int64)] = []
        for path in paths {
            if case .blocked(let reason) = safety.check(path) {
                report.failures.append(CleanFailure(path: path, reason: reason))
            } else {
                allowed.append((path, DiskScanner.measure(path)))
            }
        }
        guard !allowed.isEmpty else { return report }

        let result = runAdmin(allowed.map(\.path))
        if result == .cancelled {
            report.wasCancelled = true
            return report
        }
        // rm carries on past anything it can't delete, such as files protected
        // from root by macOS, so what's left on disk is the only reliable answer.
        for entry in allowed {
            var st = stat()
            if lstat(entry.path, &st) != 0 {
                report.bytes += entry.size
                report.removed += 1
                log("removed (admin)", entry.path, entry.size)
            } else {
                var reason = "macOS protects this, even from an administrator."
                if case .failed(let message) = result, !message.isEmpty { reason = message }
                report.failures.append(CleanFailure(path: entry.path, reason: reason))
            }
        }
        return report
    }

    /// The password goes to macOS's own dialog, and the privilege ends when this
    /// one command does. FreeMyMac never sees the password or stays running as root.
    @Sendable public static func runAdminPrompt(_ paths: [String]) -> AdminResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", adminScript(paths: paths)]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()
        do {
            try process.run()
        } catch {
            return .failed(error.localizedDescription)
        }
        let message = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        if process.terminationStatus == 0 { return .finished }
        return message.contains("-128") ? .cancelled : .failed(message.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public static func adminScript(paths: [String]) -> String {
        let quoted = paths.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let command = "/bin/rm -rf -- " + quoted.joined(separator: " ")
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" with administrator privileges"
    }

    // MARK: - Helpers

    private func makeWritable(_ path: String) {
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return }
        chmod(path, st.st_mode | S_IRWXU)
        guard let names = try? fm.contentsOfDirectory(atPath: path) else { return }
        for name in names { makeWritable(path + "/" + name) }
    }

    private func log(_ action: String, _ path: String, _ size: Int64) {
        let line = "\(ISO8601DateFormatter().string(from: Date()))\t\(action)\t\(formatBytes(size))\t\(path)\n"
        let url = URL(fileURLWithPath: env.logPath)
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
