import Foundation
import CoreServices

/// Listens to macOS's record of file-system changes (FSEvents). Started from a
/// saved event ID, it first replays every folder that changed since then, even
/// while FreeMyMac wasn't running, and then keeps reporting new changes live.
public final class ChangeWatcher: @unchecked Sendable {
    public enum Signal: Sendable {
        case changes([DiskChange], lastEventID: UInt64)
        /// Everything since the starting event has been delivered.
        case caughtUp(lastEventID: UInt64)
        /// macOS can't say what changed, so only a full scan is reliable.
        case lostTrack
    }

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.pavitra.freemymac.changes")
    private let handler: @Sendable (Signal) -> Void

    /// Changes are batched for `latency` seconds before they're reported.
    public init?(path: String, since eventID: UInt64, latency: Double = 2, handler: @escaping @Sendable (Signal) -> Void) {
        self.handler = handler
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
            guard let info else { return }
            let watcher = Unmanaged<ChangeWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self)
            var events: [(String, FSEventStreamEventFlags, FSEventStreamEventId)] = []
            events.reserveCapacity(count)
            for index in 0..<count {
                guard let path = list[index] as? String else { continue }
                events.append((path, flags[index], ids[index]))
            }
            watcher.deliver(events)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)
        guard let created = FSEventStreamCreate(nil, callback, &context, [path] as CFArray, eventID, latency, flags) else {
            return nil
        }
        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            stream = nil
            return nil
        }
    }

    deinit { stop() }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func deliver(_ events: [(String, FSEventStreamEventFlags, FSEventStreamEventId)]) {
        let lost = UInt32(kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagEventIdsWrapped)
        let rescanBelow = UInt32(kFSEventStreamEventFlagMustScanSubDirs)
        let historyDone = UInt32(kFSEventStreamEventFlagHistoryDone)

        var changes: [DiskChange] = []
        var lastID: UInt64 = 0
        var caughtUp = false
        for (path, flags, id) in events {
            if flags & lost != 0 {
                handler(.lostTrack)
                return
            }
            if flags & historyDone != 0 {
                caughtUp = true
                continue
            }
            lastID = max(lastID, id)
            changes.append(DiskChange(path: path, everything: flags & rescanBelow != 0))
        }
        if !changes.isEmpty { handler(.changes(changes, lastEventID: lastID)) }
        if caughtUp { handler(.caughtUp(lastEventID: lastID)) }
    }

    /// The newest event ID macOS has issued. A scan that starts now is current
    /// as of this event.
    public static var currentEventID: UInt64 { FSEventsGetCurrentEventId() }

    /// Identifies the change history of the volume holding `path`. It changes
    /// if macOS erases that history, which makes saved event IDs meaningless.
    public static func historyID(for path: String) -> String? {
        var st = stat()
        guard lstat(path, &st) == 0, let uuid = FSEventsCopyUUIDForDevice(st.st_dev) else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }
}
